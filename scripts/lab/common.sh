#!/usr/bin/env bash
# Shared helpers for the lab tools (ledger, capsule, board, fail).
# Sourced, never executed directly.
#
# State lives in the RESEARCH repo these tools are run from, not in this harness.
# All of it is gitignored:
#   <repo>/.oma-lab/ledger.jsonl       every run
#   <repo>/.oma-lab/experiments.jsonl  experiment claims
#   <repo>/.oma-lab/failures.jsonl     failed commands
#   <repo>/.oma-lab/runs/<id>/         reproducibility bundles
#   <repo>/.oma-lab/CURRENT            the run other tools join against
#
# The name says who owns it: a plain `runs/` collides with what TensorBoard,
# W&B and Hydra already write. The ledger is deliberately NOT git-tracked —
# a repo doing dozens of runs a day would turn an append-only tracked JSONL
# into commit noise and a merge-conflict generator. Curating a subset into
# docs/ is a separate, explicit act.

set -uo pipefail

LAB_STATE_DIRNAME=".oma-lab"

lab_warn() { printf 'lab: %s\n' "$*" >&2; }
lab_die()  { printf 'lab: %s\n' "$*" >&2; exit 1; }

# Repo root, or the working directory when this is not a git checkout. Every
# path below hangs off this, so it is resolved once with pwd -P — a path spelled
# two ways compares unequal and silently splits state into two trees.
lab_repo_root() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
  (cd "$root" && pwd -P)
}

# Path only — creating the directory is the writer's job, not the reader's.
# When this also ran mkdir, asking a read-only question created state: running
# `oma-lab fail --help` or `board list` in any directory left an empty
# .oma-lab/ behind, including in the harness checkout itself. Every writer
# already creates what it needs (lab_append_jsonl, capsule.sh's runs dir), so
# there is nothing for this to fall back on.
lab_state_dir() {
  printf '%s' "${LAB_ROOT:-$(lab_repo_root)}/$LAB_STATE_DIRNAME"
}

lab_ledger_path()      { printf '%s/ledger.jsonl'      "$(lab_state_dir)"; }
lab_experiments_path() { printf '%s/experiments.jsonl' "$(lab_state_dir)"; }
lab_failures_path()    { printf '%s/failures.jsonl'    "$(lab_state_dir)"; }

# Sortable and unique: a UTC stamp for ordering plus entropy, because two runs
# launched in the same second are normal on a cluster.
lab_new_run_id() {
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
}

# Is this id one the ledger actually knows? Parsed, not grepped, because the row
# is JSON and a substring match would also hit a run_id quoted inside cmd.
lab_run_id_in_ledger() {
  [ -n "${1:-}" ] || return 1
  local n
  n="$(lab_jsonl_query "$(lab_ledger_path)" '
print(sum(1 for r in rows if r.get("run_id") == args[0]))
' "$1")"
  [ "${n:-0}" != "0" ]
}

# The join key. Explicit --run-id beats the environment, which beats the last
# run recorded in this repo.
#
# The CURRENT fallback is verified against the ledger; OMA_RUN_ID is not, and the
# asymmetry is the point. `oma-lab run` writes CURRENT and exports OMA_RUN_ID at
# ledger.sh:155-156, before the wrapped command, and appends the row at :204 after
# it exits — so inside a run the id legitimately has no row yet, and the export is
# what callers see. Reaching the file branch instead means the run is over, and
# then a pointer the ledger cannot resolve is a dangling join key: reproduced by
# writing a bogus id into CURRENT, after which `capsule save` reported success,
# created .oma-lab/runs/<bogus>/, and stamped a row whose run_id matched nothing.
lab_current_run_id() {
  if [ -n "${OMA_RUN_ID:-}" ]; then printf '%s' "$OMA_RUN_ID"; return 0; fi
  local f; f="$(lab_state_dir)/CURRENT"
  [ -f "$f" ] || return 1
  local id; id="$(head -n1 "$f")"
  [ -n "$id" ] || return 1
  if ! lab_run_id_in_ledger "$id"; then
    printf 'lab: %s/CURRENT names run %s but the ledger has no such run.\n' \
      "$(lab_state_dir)" "$id" >&2
    printf '     Pass --run-id explicitly, or start a new run with `oma-lab run`.\n' >&2
    return 1
  fi
  printf '%s' "$id"
}

lab_set_current_run_id() {
  local d; d="$(lab_state_dir)"
  mkdir -p "$d" || lab_die "cannot create state dir: $d"
  printf '%s\n' "$1" > "$d/CURRENT"
}

# --- git state -------------------------------------------------------------

# Every git read is aimed at the repo the state belongs to, not at wherever the
# caller happens to be standing. --repo sets LAB_ROOT, but it used to redirect
# only the state PATH: a Slurm job launched from the submit directory wrote its
# ledger into the target repo while stamping every row with the LAUNCHER's
# commit and diff hash. That is worse than not recording it, because the row
# looks authoritative and answers "which code produced this number" with the
# wrong commit. Verified: launcher HEAD appeared in the target's ledger.
lab_git() { git -C "${LAB_ROOT:-.}" "$@"; }

lab_git_commit() { lab_git rev-parse HEAD 2>/dev/null || printf 'no-head'; }

lab_git_dirty() {
  lab_git rev-parse --show-toplevel >/dev/null 2>&1 || { printf 'false'; return; }
  if [ -n "$(lab_git status --porcelain 2>/dev/null)" ]; then printf 'true'; else printf 'false'; fi
}

# Content fingerprint of uncommitted work. Two runs at the same commit are not
# the same run if the working tree differs, which is the normal case mid-session.
# Our own state dir is excluded, and that is not cosmetic: recording a failure
# creates .oma-lab/failures.jsonl, which is untracked, which would change the
# fingerprint — so the very next check would conclude "the tree changed since"
# and wave through a retry that is certain to fail identically.
lab_diff_hash() {
  lab_git rev-parse --show-toplevel >/dev/null 2>&1 || { printf 'nogit'; return; }
  {
    lab_git diff HEAD -- . ":(exclude)$LAB_STATE_DIRNAME" 2>/dev/null
    lab_git ls-files --others --exclude-standard 2>/dev/null | grep -v "^$LAB_STATE_DIRNAME/"
  } | sha256sum | cut -c1-16
}

lab_sha_file() {
  [ -f "$1" ] || { printf 'missing'; return; }
  sha256sum "$1" | cut -c1-16
}

# --- json ------------------------------------------------------------------

# Build one JSON object from key value pairs. Values are always emitted as
# strings except for a bare true/false/null or a plain number, so a command
# containing quotes, newlines or backslashes cannot break the row.
lab_json_obj() {
  python3 -c '
import json, math, sys
MAX = 8192          # one field; a row is a record, not a log dump
it = iter(sys.argv[1:])
out = {}
for k in it:
    v = next(it, "")
    if len(v) > MAX:
        v = v[:MAX] + "...[truncated]"
    if v in ("true", "false"): out[k] = (v == "true")
    elif v == "null": out[k] = None
    else:
        try: out[k] = int(v)
        except ValueError:
            try:
                f = float(v)
                # NaN/inf are not JSON. Keeping the literal text loses nothing
                # and beats raising, which would drop the whole row.
                out[k] = f if math.isfinite(f) else v
            except ValueError: out[k] = v
    # a value that only looks numeric must stay a string when the key says so
    # job/tag/id are identifiers, not quantities: a Slurm job id read back as an
    # int loses leading zeros and blows up on string concatenation downstream.
    if k in ("cmd", "run_id", "commit", "id", "note", "reason", "repo",
             "job", "tag", "slurm_job", "metrics", "result", "next",
             "hypothesis", "owner", "cmd_hash", "git_state") and out[k] is not None:
        out[k] = v
print(json.dumps(out, ensure_ascii=False, sort_keys=True, allow_nan=False))
' "$@"
}

# Append one JSONL row under a lock.
#
# A bare `>> file` is only atomic for writes under PIPE_BUF, and a row carrying
# a long command or a metrics blob exceeds that. This session already lost 10 of
# 12 concurrent journal entries to exactly this, so the lock is here from the
# start rather than after the next incident. The lock lives outside the state
# dir so a synced or shared filesystem does not replicate it.
# A write that does not happen is fatal, not a warning. No caller checked the
# return value, so on a read-only repo `board claim` printed "claimed" and
# exited 0 having recorded nothing — the tool then reports an experiment as
# taken that no file remembers, which is worse than refusing to claim it.
# Failing here means the caller cannot get it wrong by omission.
lab_append_jsonl() {
  local file="$1" row="$2" dir
  dir="$(dirname "$file")"
  mkdir -p "$dir" || lab_die "cannot create $dir"
  # HOME may be unset in a batch context (cron, a Slurm prologue); falling back
  # keeps the lock optional rather than making an unset variable fatal.
  local lockdir="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/oh-my-agent-env/locks"
  if command -v flock >/dev/null 2>&1 && mkdir -p "$lockdir" 2>/dev/null; then
    local lock rc=0
    lock="$lockdir/lab-$(printf '%s' "$file" | sha256sum | cut -c1-16).lock"
    if exec 8>"$lock" 2>/dev/null && flock -w 10 8; then
      printf '%s\n' "$row" >> "$file" || rc=$?
      flock -u 8
      [ "$rc" -eq 0 ] || lab_die "cannot write $file"
      return 0
    fi
    lab_warn "lock unavailable — appending unserialized"
  fi
  printf '%s\n' "$row" >> "$file" || lab_die "cannot write $file"
}

# Read every row of a JSONL file as python objects and run CODE over `rows`.
# Missing file means an empty list, never an error: an empty ledger is the
# normal state of a fresh repo, not a failure.
lab_jsonl_query() {
  local file="$1" code="$2"; shift 2
  python3 -c '
import json, sys
path, code = sys.argv[1], sys.argv[2]
rows = []
try:
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try: rows.append(json.loads(line))
            except ValueError: pass          # a torn row must not hide the rest
except FileNotFoundError:
    pass
args = sys.argv[3:]
exec(code)
' "$file" "$code" "$@"
}

# --- misc ------------------------------------------------------------------

lab_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Normalized command fingerprint: collapse whitespace so re-running the same
# thing with different spacing is recognized as the same thing.
lab_cmd_hash() {
  printf '%s' "$*" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' | sha256sum | cut -c1-16
}

# Keep run state out of git without touching the user's .gitignore.
#
# .gitignore is a tracked file: appending to it puts harness residue in the
# user's commits and in every collaborator's checkout, for a directory that is
# purely local. .git/info/exclude is the same mechanism, private to this
# checkout, and needs no permission. If it is missing we are not in a git repo,
# and there is nothing to ignore.
lab_ensure_gitignore() {
  local gitdir
  # --absolute-git-dir, not --git-dir: with `-C` aimed at another repo the plain
  # form still answers ".git", which resolves against the CALLER's cwd. That is
  # how `run --repo target` came to write its exclude line into the launcher's
  # repo and none into the target's — the one repo that was about to get a
  # .oma-lab/ directory was the one left un-excluded.
  gitdir="$(lab_git rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  local ex="$gitdir/info/exclude"
  mkdir -p "$(dirname "$ex")" 2>/dev/null || return 0
  grep -qxF "$LAB_STATE_DIRNAME/" "$ex" 2>/dev/null && return 0
  printf '%s/\n' "$LAB_STATE_DIRNAME" >> "$ex"
  lab_warn "excluded $LAB_STATE_DIRNAME/ via .git/info/exclude (your .gitignore is untouched)"
}
