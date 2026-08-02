#!/usr/bin/env bash
# Find out how the jobs the ledger launched actually ended.
#
#   oma-lab reconcile scan            what state is each recorded job in now?
#   oma-lab reconcile apply           record the ones that reached a terminal state
#   oma-lab reconcile list [-n N]     what has been recorded
#
# Options: --job ID (just this one), --repo PATH (a repo you are not standing in)
#
# A Slurm job outlives the session that submitted it. `oma-lab run -- sbatch
# train.sh` records exit=0, because that is sbatch's exit — the submission
# worked. The training may still OOM an hour later, and nothing ever went back
# to say so: the ledger row keeps claiming success for a run that failed.
#
# This is the part that closes that loop. It never edits a ledger row — the
# launch record is what it is — it appends the terminal outcome beside it, so
# `run list` can mark the rows whose story did not end where they said it did.
set -uo pipefail

# shellcheck disable=SC1091
. "${LAB_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}/common.sh"

verb="${1:-list}"; shift || true

ONE_JOB="" LIMIT=20
while [ $# -gt 0 ]; do
  case "$1" in
    --job|--repo|-n)
      [ $# -ge 2 ] || lab_die "$1 needs a value"
      case "$1" in
        --job)  ONE_JOB="$2" ;;
        -n)     LIMIT="$2" ;;
        --repo) LAB_ROOT="$(cd "$2" && pwd -P)" || lab_die "no such repo: $2"; export LAB_ROOT ;;
      esac
      shift 2 ;;
    -h|--help) verb="help"; shift ;;
    *) lab_die "unknown option: $1" ;;
  esac
done

LAB_ROOT="${LAB_ROOT:-$(lab_repo_root)}"
export LAB_ROOT
RECONCILED="$(lab_state_dir)/reconciled.jsonl"

SACCT="${OMA_SACCT_CMD:-sacct}"
SQUEUE="${OMA_SQUEUE_CMD:-squeue}"

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
    "$(readlink -f "${BASH_SOURCE[0]}")"
}

# Refuse rather than report a clean board we never looked at. Without a way to
# query Slurm, "no finished jobs" and "no idea" produce the same output, and the
# caller acts on the first reading. This is the same rule `data leakage` follows.
#
# `command -v` answers "is the binary on PATH", which is not the question. With
# slurmdbd down, sacct is installed and fails every query: the presence check
# passed, every job came back UNKNOWN, and apply printed "0 newly finished, N
# still open" — word for word what it prints when the jobs really are running.
# So ask a question whose answer does not depend on any particular job: job 0
# never exists, and a healthy sacct answers that with no rows and exit 0.
require_slurm() {
  command -v "$SACCT"  >/dev/null 2>&1 &&
    "$SACCT"  -n -X -j 0 --format=State >/dev/null 2>&1 && return 0
  command -v "$SQUEUE" >/dev/null 2>&1 &&
    "$SQUEUE" -h -o '%T' >/dev/null 2>&1 && return 0
  printf 'reconcile: cannot query Slurm — %s and %s are both missing or failing\n' \
    "$SACCT" "$SQUEUE" >&2
  printf '           A job that cannot be looked up has not been shown to be running.\n' >&2
  printf '           (override the binaries with OMA_SACCT_CMD / OMA_SQUEUE_CMD)\n' >&2
  exit 2
}

# Distinct non-empty job ids the ledger recorded, in launch order.
job_ids() {
  if [ -n "$ONE_JOB" ]; then printf '%s\n' "$ONE_JOB"; return 0; fi
  lab_jsonl_query "$(lab_ledger_path)" '
seen = set()
for r in rows:
    j = str(r.get("slurm_job") or "").strip()
    if j and j not in seen:
        seen.add(j); print(j)
'
}

# The states that mean the job is over. One list, shared by is_terminal and the
# awk selector below — two copies would drift, and the copy that drifted would
# be the one deciding whether a finished job is ever recorded.
TERMINAL_STATES="COMPLETED FAILED CANCELLED TIMEOUT OUT_OF_MEMORY NODE_FAIL BOOT_FAIL DEADLINE PREEMPTED"

# CANCELLED arrives as "CANCELLED by 1000", so match the leading word only. A
# trailing "+" means sacct truncated a longer state name, not a different state.
is_terminal() {
  local head="${1%% *}"
  head="${head%+}"
  case " $TERMINAL_STATES " in *" $head "*) return 0 ;; esac
  return 1
}

# "<state>\t<exit>\t<elapsed>\t<source>" for one id.
#
# sacct first: a finished job leaves squeue but stays in the accounting db, so
# asking squeue first would report a completed run as simply absent.
#
# Which of sacct's rows is "the job" is the whole difficulty here:
#
#   12345          the job                    <- an answer
#   12345.batch    a step inside it           <- not an answer; its state differs
#   12345_0        array element 0            <- an answer, and there are many
#   12345+0        heterogeneous component 0  <- likewise
#
# Taking whichever row came first filed a step's outcome as the job's. Matching
# JobID exactly fixed that and broke something bigger: `sbatch --array` records
# the parent id 12345, no row is ever named exactly that, so every sweep went
# UNKNOWN -> "still open" forever. Both bugs are silent and both look like a
# healthy board, so the rule has to name the step rows rather than the job ones:
# a step is the row with a dot in it, and everything else whose id before the
# "_" or "+" is the one asked for belongs to this job.
#
# An array is many endings and the caller wants one. Still-running wins first —
# the job is not over while any element runs — then a non-COMPLETED ending, so a
# sweep where one element OOM'd cannot report itself as COMPLETED.
job_state() {
  local jid="$1" line="" st
  if command -v "$SACCT" >/dev/null 2>&1; then
    line="$("$SACCT" -j "$jid" --format=JobID,State,ExitCode,Elapsed -n -P 2>/dev/null \
            | awk -F'|' -v want="$jid" -v term=" $TERMINAL_STATES " '
        index($1, ".") { next }                       # a step, not the job
        { id = $1; sub(/[_+].*$/, "", id) }
        id != want { next }
        {
          state = $2
          sub(/^[ \t]+/, "", state); sub(/[ \t]+$/, "", state)
          head = state; sub(/ .*$/, "", head); sub(/\+$/, "", head)
          row = state "|" $3 "|" $4
          if (index(term, " " head " ") == 0) { if (!o++) open = row }
          else if (head != "COMPLETED") { if (!b++) bad = row }
          else if (!c++) ok = row
        }
        END {
          if (o) print open; else if (b) print bad; else if (c) print ok
        }')"
    if [ -n "$line" ]; then
      # Trim the edges, keep the inside. `tr -d ' '` turns sacct's
      # "CANCELLED by 1000" into "CANCELLEDby1000", which then matches nothing
      # in is_terminal — so a cancelled job stayed "still open" forever and was
      # never recorded, which is the one thing this tool exists to prevent.
      printf '%s\t%s\t%s\tsacct\n' \
        "$(printf '%s' "$line" | cut -d'|' -f1)" \
        "$(printf '%s' "$line" | cut -d'|' -f2)" \
        "$(printf '%s' "$line" | cut -d'|' -f3)"
      return 0
    fi
  fi
  if command -v "$SQUEUE" >/dev/null 2>&1; then
    st="$("$SQUEUE" -j "$jid" -h -o '%T' 2>/dev/null | head -n1)"
    [ -n "$st" ] && { printf '%s\t\t\tsqueue\n' "$st"; return 0; }
  fi
  printf 'UNKNOWN\t\t\tnone\n'
}

already_done() {
  lab_jsonl_query "$RECONCILED" '
target = args[0]
sys.exit(0 if any(str(r.get("slurm_job")) == target for r in rows) else 1)
' "$1"
}

case "$verb" in
  scan)
    require_slurm
    any=0
    while IFS= read -r jid; do
      [ -n "$jid" ] || continue
      any=1
      info="$(job_state "$jid")"
      printf '%-12s %-14s %s\n' "$jid" "$(printf '%s' "$info" | cut -f1)" \
             "$(printf '%s' "$info" | cut -f4)"
    done <<EOF
$(job_ids)
EOF
    [ "$any" = 1 ] || lab_warn "no job ids in the ledger — was anything submitted with sbatch?"
    ;;

  apply)
    require_slurm
    n_done=0 n_open=0
    while IFS= read -r jid; do
      [ -n "$jid" ] || continue
      already_done "$jid" && continue
      info="$(job_state "$jid")"
      state="$(printf '%s' "$info" | cut -f1)"
      xcode="$(printf '%s' "$info" | cut -f2)"
      elapsed="$(printf '%s' "$info" | cut -f3)"
      src="$(printf '%s' "$info" | cut -f4)"
      # UNKNOWN is not an ending. Recording it would make the row permanent —
      # already_done skips it forever — and the job may simply not be in the
      # accounting db yet.
      if ! is_terminal "$state"; then
        n_open=$((n_open + 1)); continue
      fi
      lab_append_jsonl "$RECONCILED" "$(lab_json_obj \
        ts "$(lab_now)" slurm_job "$jid" state "$state" exit_code "$xcode" \
        elapsed "$elapsed" source "$src" repo "$LAB_ROOT")"
      n_done=$((n_done + 1))
      printf 'reconciled: %s -> %s (exit %s, %s)\n' "$jid" "$state" "$xcode" "$elapsed"
    done <<EOF
$(job_ids)
EOF
    printf 'reconcile: %d newly finished, %d still open\n' "$n_done" "$n_open" >&2
    ;;

  list)
    lab_jsonl_query "$RECONCILED" '
n = int(args[0])
for r in rows[-n:]:
    # `or "?"` is wrong here: exit_code is not on lab_json_obj identifier
    # allow-list, so a bare "0" is stored as the int 0, and 0 is falsy. A job
    # that exited cleanly would print exit=? — the one value that reads as
    # "we do not know" is the one we know best. Only absent means unknown.
    xc = r.get("exit_code")
    xc = "?" if xc is None or xc == "" else xc
    print("%s  job=%-10s %-14s exit=%-6s %s" % (
        r.get("ts","?"), r.get("slurm_job","?"), r.get("state","?"),
        xc, r.get("elapsed") or ""))
print("(%d reconciled)" % len(rows))
' "$LIMIT"
    ;;

  ""|help|-h|--help) usage ;;

  *) lab_die "unknown verb: $verb" ;;
esac
