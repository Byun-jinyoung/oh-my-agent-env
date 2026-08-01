#!/usr/bin/env bash
# Freeze what a run actually depended on, so a number stays traceable.
#
#   oma-lab capsule save [--run-id ID] [--config F]... [--output F]... [--note "..."]
#   oma-lab capsule list
#   oma-lab capsule show ID
#   oma-lab capsule whence FILE     which run produced this checkpoint?
#
# Saves to .oma-lab/runs/<run-id>/: the commit, the uncommitted diff as a real
# patch, fingerprints of the configs read and the outputs written, the seed, and
# the GPU it ran on. Six months later "which code produced checkpoint-best.pt"
# has an answer instead of a guess.
#
# Deliberately not here yet: `reproduce` (re-running is a judgement call, not a
# button) and strict `verify`. `whence` is kept because it is the question that
# actually gets asked, and the output fingerprints already make it nearly free.
set -uo pipefail

# shellcheck disable=SC1091
. "${LAB_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}/common.sh"

RID="" NOTE="" ; CONFIGS=() ; OUTPUTS=()
verb="${1:-list}"; shift || true
POSITIONAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run-id|--config|--output|--note|--repo)
      [ $# -ge 2 ] || lab_die "$1 needs a value"
      case "$1" in
        --run-id) RID="$2" ;;
        --config) CONFIGS+=("$2") ;;
        --output) OUTPUTS+=("$2") ;;
        --note)   NOTE="$2" ;;
        --repo)   LAB_ROOT="$(cd "$2" && pwd -P)" || lab_die "no such repo: $2"; export LAB_ROOT ;;
      esac
      shift 2 ;;
    -*) lab_die "unknown option: $1" ;;
    *) POSITIONAL="$1"; shift ;;
  esac
done

ROOT="${LAB_ROOT:-$(lab_repo_root)}"
# --config/--output and the path `whence` looks up are relative to the REPO,
# not to the caller's cwd. Without this, `capsule save --repo target --output
# out/model.txt` run from anywhere else fingerprinted a file that was never
# there and recorded "missing:out/model.txt" — a capsule that records the
# absence of the artifact it exists to pin. Set LAB_ROOT too, so the state path
# and the git helpers resolve against the same repo we just moved into.
LAB_ROOT="$ROOT"; export LAB_ROOT
cd "$ROOT" || lab_die "cannot enter repo root: $ROOT"
RUNS_DIR="$(lab_state_dir)/runs"
INDEX="$(lab_state_dir)/capsules.jsonl"

# sha:path pairs, one per line, for a list of files.
fingerprint_list() {
  local f
  for f in "$@"; do
    [ -n "$f" ] || continue
    printf '%s:%s\n' "$(lab_sha_file "$f")" "$f"
  done
}

case "$verb" in
  save)
    [ -n "$RID" ] || RID="$(lab_current_run_id)" || lab_die "no run id — pass --run-id or run 'oma-lab run' first"
    dir="$RUNS_DIR/$RID"
    mkdir -p "$dir" || lab_die "cannot create $dir"

    # The patch is the part that is genuinely irrecoverable later: the commit is
    # in git forever, the uncommitted delta is not.
    ( cd "$ROOT" && git diff HEAD -- . ":(exclude)$LAB_STATE_DIRNAME" ) > "$dir/uncommitted.patch" 2>/dev/null || true

    gpu=""
    if command -v nvidia-smi >/dev/null 2>&1; then
      gpu="$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
    fi

    cfg_fp="$(fingerprint_list "${CONFIGS[@]+"${CONFIGS[@]}"}" | paste -sd';' -)"
    out_fp="$(fingerprint_list "${OUTPUTS[@]+"${OUTPUTS[@]}"}" | paste -sd';' -)"

    lab_json_obj \
      ts "$(lab_now)" run_id "$RID" commit "$(lab_git_commit)" dirty "$(lab_git_dirty)" \
      git_state "$(lab_git_commit | cut -c1-12):$(lab_diff_hash)" \
      patch_bytes "$(wc -c < "$dir/uncommitted.patch" 2>/dev/null || printf 0)" \
      python "$(command -v python3 >/dev/null && python3 -V 2>&1 | tr -d '\n')" \
      gpu "$gpu" seed "${SEED:-${PYTHONHASHSEED:-}}" \
      configs "$cfg_fp" outputs "$out_fp" note "$NOTE" repo "$ROOT" \
      > "$dir/capsule.json"

    lab_append_jsonl "$INDEX" "$(lab_json_obj \
      ts "$(lab_now)" run_id "$RID" commit "$(lab_git_commit)" \
      configs "$cfg_fp" outputs "$out_fp" note "$NOTE" repo "$ROOT")"

    printf 'capsule: saved %s (%s)\n' "$RID" "$dir"
    [ -n "$out_fp" ] || lab_warn "no --output given — 'whence' will not find anything for this run"
    ;;

  list)
    lab_jsonl_query "$INDEX" '
for r in rows:
    print("%s  %-24s %s  %s" % (r.get("ts","?"), r.get("run_id","?"),
                                (r.get("commit") or "?")[:8], r.get("note") or ""))
print("(%d capsule(s))" % len(rows))
'
    ;;

  show)
    [ -n "$POSITIONAL" ] || lab_die "show requires a run id"
    f="$RUNS_DIR/$POSITIONAL/capsule.json"
    [ -f "$f" ] || lab_die "no capsule for $POSITIONAL"
    python3 -m json.tool "$f"
    p="$RUNS_DIR/$POSITIONAL/uncommitted.patch"
    [ -s "$p" ] && printf '\nuncommitted.patch: %s bytes (%s)\n' "$(wc -c < "$p")" "$p"
    ;;

  whence)
    [ -n "$POSITIONAL" ] || lab_die "whence requires a file"
    [ -f "$POSITIONAL" ] || lab_die "no such file: $POSITIONAL"
    lab_jsonl_query "$INDEX" '
sha, path = args[0], args[1]
hits = []
for r in rows:
    for pair in (r.get("outputs") or "").split(";"):
        if pair.startswith(sha + ":"):
            hits.append(r); break
if not hits:
    print("whence: no capsule recorded %s (sha %s)" % (path, sha))
    print("        Was it saved with --output?")
    sys.exit(1)
for r in hits:
    print("%s  run=%s  commit=%s  %s" % (r.get("ts","?"), r.get("run_id","?"),
                                         (r.get("commit") or "?")[:8], r.get("note") or ""))
' "$(lab_sha_file "$POSITIONAL")" "$POSITIONAL"
    ;;

  ""|-h|--help|help)
    sed -n '2,9p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \?//'
    ;;

  *) lab_die "unknown verb: $verb" ;;
esac
