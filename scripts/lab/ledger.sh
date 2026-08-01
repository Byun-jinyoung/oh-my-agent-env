#!/usr/bin/env bash
# Record every run, so the next session can look up what was already tried.
#
#   oma-lab run [opts] -- CMD...    gate, execute, record; exits with CMD's code
#   oma-lab top --metric KEY [--min] [-n N]
#   oma-lab run list [-n N]
#
# Options for `run`:
#   --metrics k=v,k=v   scalars to record (accuracy, loss, rmse, ...)
#   --tag NAME          free label for grouping
#   --no-gate --reason  skip the pre-flight gate; the reason is recorded
#   --repo PATH         repo root, for a job launched from elsewhere (Slurm)
#
# The pre-flight gate is the research repo's own executable scripts/check.sh.
# A failing gate aborts BEFORE the command runs — the cost it saves is hours of
# GPU time spent training code that was already broken. It must never call back
# into oma-lab, or the gate and the ledger recurse.
set -uo pipefail

# shellcheck disable=SC1091
. "${LAB_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}/common.sh"

verb="${1:-}"; shift || true

METRICS="" TAG="" NOGATE=0 REASON="" LIMIT=20 METRIC="" ORDER=max

# Render the header up to the first non-comment line. `oma-lab` routes `run`
# and `top` straight here as the verb, so --help arrived as an option and died
# on "unknown option" — the help block below the dispatch was unreachable from
# the only spelling a user would try.
ledger_usage() {
  # Stops at the first non-comment line rather than at `set -`; see oma-lab.
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
    "$(readlink -f "${BASH_SOURCE[0]}")"
}

parse_common() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; CMD_ARGV=("$@"); return 0 ;;
      --metrics|--tag|--reason|--repo|--metric|-n)
        [ $# -ge 2 ] || lab_die "$1 needs a value"
        case "$1" in
          --metrics) METRICS="$2" ;;
          --tag)     TAG="$2" ;;
          --reason)  REASON="$2" ;;
          --metric)  METRIC="$2" ;;
          -n)        LIMIT="$2" ;;
          --repo)    LAB_ROOT="$(cd "$2" && pwd -P)" || lab_die "no such repo: $2"; export LAB_ROOT ;;
        esac
        shift 2 ;;
      -h|--help) ledger_usage; exit 0 ;;
      --no-gate) NOGATE=1; shift ;;
      --min) ORDER=min; shift ;;
      --max) ORDER=max; shift ;;
      *) lab_die "unknown option: $1 (put the command after --)" ;;
    esac
  done
  CMD_ARGV=()
}

# The ledger path is resolved at each use, not cached here. --repo is what sets
# LAB_ROOT, and parse_common runs after this point, so a cached path pointed at
# whatever directory the command was launched from: `run --repo /target` wrote
# ledger.jsonl into the CALLER's repo while CURRENT landed in the target, and a
# run launched from this harness wrote straight into it. Resolving late means a
# future branch cannot reintroduce the ordering bug by forgetting to reassign.
case "$verb" in
  run)
    if [ "${1:-}" = "list" ]; then
      shift; parse_common "$@"
      lab_jsonl_query "$(lab_ledger_path)" '
n = int(args[0])
for r in rows[-n:]:
    print("%s  %s  exit=%-3s %6.1fs  %s" % (
        r.get("ts","?"), (r.get("run_id") or "?")[:22], r.get("exit","?"),
        r.get("duration_s") or 0.0, (r.get("cmd") or "")[:60]))
print("(%d runs recorded)" % len(rows))
' "$LIMIT"
      exit 0
    fi

    CMD_ARGV=()
    parse_common "$@"
    [ "${#CMD_ARGV[@]}" -gt 0 ] || lab_die "nothing to run — put the command after --"
    CMD_STR="${CMD_ARGV[*]}"

    [ "$NOGATE" = 1 ] && [ -z "$REASON" ] && lab_die "--no-gate requires --reason (it gets recorded)"

    root="${LAB_ROOT:-$(lab_repo_root)}"
    lab_ensure_gitignore

    # Same code, same tree, same command: almost always an accident.
    lab_jsonl_query "$(lab_ledger_path)" '
h, g = args[0], args[1]
prev = [r for r in rows if r.get("cmd_hash") == h and r.get("git_state") == g]
if prev:
    sys.stderr.write("run: warning — identical run already recorded (%s, exit=%s)\n"
                     % (prev[-1].get("ts","?"), prev[-1].get("exit","?")))
' "$(lab_cmd_hash "$CMD_STR")" "$(lab_git_commit | cut -c1-12):$(lab_diff_hash)"

    gate="skipped"
    if [ "$NOGATE" = 1 ]; then
      gate="skipped: $REASON"
      lab_warn "gate skipped — $REASON"
    elif [ -x "$root/scripts/check.sh" ]; then
      printf 'run: gate — %s/scripts/check.sh\n' "$root" >&2
      if ( cd "$root" && ./scripts/check.sh >&2 ); then
        gate="passed"
      else
        gate="failed"
        lab_append_jsonl "$(lab_ledger_path)" "$(lab_json_obj \
          ts "$(lab_now)" run_id aborted cmd "$CMD_STR" cmd_hash "$(lab_cmd_hash "$CMD_STR")" \
          commit "$(lab_git_commit)" git_state "$(lab_git_commit | cut -c1-12):$(lab_diff_hash)" \
          gate failed exit 1 aborted true repo "$root")"
        lab_die "gate failed — not launching. Fix it, or rerun with --no-gate --reason '...'"
      fi
    else
      gate="none"
    fi

    RID="$(lab_new_run_id)"
    lab_set_current_run_id "$RID"
    export OMA_RUN_ID="$RID"
    printf 'run: %s\n' "$RID" >&2

    start=$(date +%s)
    ( cd "$root" && "${CMD_ARGV[@]}" )
    code=$?
    dur=$(( $(date +%s) - start ))

    lab_append_jsonl "$(lab_ledger_path)" "$(lab_json_obj \
      ts "$(lab_now)" run_id "$RID" cmd "$CMD_STR" cmd_hash "$(lab_cmd_hash "$CMD_STR")" \
      commit "$(lab_git_commit)" dirty "$(lab_git_dirty)" \
      git_state "$(lab_git_commit | cut -c1-12):$(lab_diff_hash)" \
      exit "$code" duration_s "$dur" gate "$gate" tag "$TAG" \
      slurm_job "${SLURM_JOB_ID:-}" metrics "$METRICS" repo "$root")"

    # A failed run is worth remembering across sessions, not just recording.
    if [ "$code" -ne 0 ]; then
      bash "${LAB_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}/fail.sh" \
        record --cmd "$CMD_STR" --exit "$code" --note "run $RID" >/dev/null 2>&1 || true
    fi
    exit "$code"
    ;;

  top)
    parse_common "$@"
    [ -n "$METRIC" ] || lab_die "top requires --metric KEY"
    lab_jsonl_query "$(lab_ledger_path)" '
key, order, n = args[0], args[1], int(args[2])
def val(r):
    for pair in (r.get("metrics") or "").split(","):
        if "=" in pair:
            k, v = pair.split("=", 1)
            if k.strip() == key:
                try: return float(v)
                except ValueError: return None
    return None
scored = [(val(r), r) for r in rows]
scored = [(v, r) for v, r in scored if v is not None]
if not scored:
    print("no runs recorded metric %r" % key); sys.exit(0)
scored.sort(key=lambda t: t[0], reverse=(order == "max"))
print("best %s (%s first), %d run(s) with this metric:" % (key, order, len(scored)))
for v, r in scored[:n]:
    print("  %-12g %s  %s  %s" % (v, r.get("ts","?"), (r.get("commit") or "?")[:8],
                                  (r.get("cmd") or "")[:50]))
' "$METRIC" "$ORDER" "$LIMIT"
    ;;

  ""|-h|--help|help) ledger_usage ;;

  *) lab_die "unknown verb: $verb" ;;
esac
