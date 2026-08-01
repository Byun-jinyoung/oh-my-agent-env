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

lab_state_dir() {
  local d="${LAB_ROOT:-$(lab_repo_root)}/$LAB_STATE_DIRNAME"
  mkdir -p "$d" || lab_die "cannot create state dir: $d"
  printf '%s' "$d"
}

lab_ledger_path()      { printf '%s/ledger.jsonl'      "$(lab_state_dir)"; }
lab_experiments_path() { printf '%s/experiments.jsonl' "$(lab_state_dir)"; }
lab_failures_path()    { printf '%s/failures.jsonl'    "$(lab_state_dir)"; }

# Sortable and unique: a UTC stamp for ordering plus entropy, because two runs
# launched in the same second are normal on a cluster.
lab_new_run_id() {
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
}

# The join key. Explicit --run-id beats the environment, which beats the last
# run recorded in this repo.
lab_current_run_id() {
  if [ -n "${OMA_RUN_ID:-}" ]; then printf '%s' "$OMA_RUN_ID"; return 0; fi
  local f; f="$(lab_state_dir)/CURRENT"
  [ -f "$f" ] && head -n1 "$f" && return 0
  return 1
}

lab_set_current_run_id() {
  printf '%s\n' "$1" > "$(lab_state_dir)/CURRENT"
}

# --- git state -------------------------------------------------------------

lab_git_commit() { git rev-parse HEAD 2>/dev/null || printf 'no-head'; }

lab_git_dirty() {
  git rev-parse --show-toplevel >/dev/null 2>&1 || { printf 'false'; return; }
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then printf 'true'; else printf 'false'; fi
}

# Content fingerprint of uncommitted work. Two runs at the same commit are not
# the same run if the working tree differs, which is the normal case mid-session.
# Our own state dir is excluded, and that is not cosmetic: recording a failure
# creates .oma-lab/failures.jsonl, which is untracked, which would change the
# fingerprint — so the very next check would conclude "the tree changed since"
# and wave through a retry that is certain to fail identically.
lab_diff_hash() {
  git rev-parse --show-toplevel >/dev/null 2>&1 || { printf 'nogit'; return; }
  {
    git diff HEAD -- . ":(exclude)$LAB_STATE_DIRNAME" 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null | grep -v "^$LAB_STATE_DIRNAME/"
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
    if k in ("cmd", "run_id", "commit", "id", "note", "reason", "repo") and out[k] is not None:
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
lab_append_jsonl() {
  local file="$1" row="$2"
  mkdir -p "$(dirname "$file")" || { lab_warn "cannot create $(dirname "$file")"; return 1; }
  local lockdir="${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-agent-env/locks"
  if command -v flock >/dev/null 2>&1 && mkdir -p "$lockdir" 2>/dev/null; then
    local lock="$lockdir/lab-$(printf '%s' "$file" | sha256sum | cut -c1-16).lock"
    if exec 8>"$lock" 2>/dev/null && flock -w 10 8; then
      printf '%s\n' "$row" >> "$file"
      flock -u 8
      return 0
    fi
    lab_warn "lock unavailable — appending unserialized"
  fi
  printf '%s\n' "$row" >> "$file"
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

lab_ensure_gitignore() {
  local root="${LAB_ROOT:-$(lab_repo_root)}"
  local gi="$root/.gitignore"
  [ -e "$gi" ] || return 0
  grep -qxF "$LAB_STATE_DIRNAME/" "$gi" 2>/dev/null && return 0
  printf '%s/\n' "$LAB_STATE_DIRNAME" >> "$gi"
  lab_warn "added $LAB_STATE_DIRNAME/ to .gitignore"
}
