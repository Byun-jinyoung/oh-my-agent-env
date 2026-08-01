#!/usr/bin/env bash
# Cross-session memory of commands that failed.
#
#   oma-lab fail record  --cmd "..." [--exit N] [--note "..."]
#   oma-lab fail check   --cmd "..."      exit 3 if this already failed and nothing changed
#   oma-lab fail resolve --cmd "..." [--note "..."]
#   oma-lab fail list
#
# The point is the retry loop across sessions: an agent that does not remember
# yesterday's failure re-runs it, waits, and fails the same way. A failure is
# keyed by the normalized command AND the git state it failed in — so an
# unchanged retry is refused, while a retry after edits is only flagged, since
# the edits may well be the fix.
set -uo pipefail

# shellcheck disable=SC1091
. "${LAB_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}/common.sh"

CMD="" NOTE="" EXITCODE=""
verb="${1:-list}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --cmd|--note|--exit|--repo)
      [ $# -ge 2 ] || lab_die "$1 needs a value"
      case "$1" in
        --cmd)  CMD="$2" ;;
        --note) NOTE="$2" ;;
        --exit) EXITCODE="$2" ;;
        # Unlike its siblings this used to swallow a failed cd, so a typo in
        # --repo silently recorded the failure against the CALLER's repo — the
        # one place a cross-session memory of broken commands must not land.
        --repo) LAB_ROOT="$(cd "$2" && pwd -P)" || lab_die "no such repo: $2"
                export LAB_ROOT ;;
      esac
      shift 2 ;;
    *) lab_die "unknown option: $1" ;;
  esac
done

FILE="$(lab_failures_path)"

# Current state of the tree, so "did anything change since it failed" is answerable.
git_state() { printf '%s:%s' "$(lab_git_commit | cut -c1-12)" "$(lab_diff_hash)"; }

need_cmd() { [ -n "$CMD" ] || lab_die "$verb requires --cmd"; }

case "$verb" in
  record)
    need_cmd
    lab_append_jsonl "$FILE" "$(lab_json_obj \
      ts "$(lab_now)" event failed cmd "$CMD" cmd_hash "$(lab_cmd_hash "$CMD")" \
      git_state "$(git_state)" exit "${EXITCODE:-1}" note "$NOTE" \
      repo "${LAB_ROOT:-$(lab_repo_root)}")"
    printf 'fail: recorded (%s)\n' "$(lab_cmd_hash "$CMD")"
    ;;

  resolve)
    need_cmd
    lab_append_jsonl "$FILE" "$(lab_json_obj \
      ts "$(lab_now)" event resolved cmd "$CMD" cmd_hash "$(lab_cmd_hash "$CMD")" \
      git_state "$(git_state)" note "$NOTE" repo "${LAB_ROOT:-$(lab_repo_root)}")"
    printf 'fail: resolved (%s)\n' "$(lab_cmd_hash "$CMD")"
    ;;

  check)
    need_cmd
    lab_jsonl_query "$FILE" '
h, now = args[0], args[1]
# Append-only log: the last event for this command is its current state.
last = None
for r in rows:
    if r.get("cmd_hash") == h:
        last = r
if last is None or last.get("event") != "failed":
    sys.exit(0)
if last.get("git_state") == now:
    sys.stderr.write(
        "fail: this command already failed at %s and nothing has changed since.\n"
        "      %s\n"
        "      Fix something or run: oma-lab fail resolve --cmd ...\n"
        % (last.get("ts", "?"), last.get("note") or last.get("cmd", "")))
    sys.exit(3)
sys.stderr.write("fail: warning — this failed before (%s), but the tree changed since.\n"
                 % last.get("ts", "?"))
sys.exit(0)
' "$(lab_cmd_hash "$CMD")" "$(git_state)"
    ;;

  list)
    lab_jsonl_query "$FILE" '
state = {}
for r in rows:
    h = r.get("cmd_hash")
    if h: state[h] = r
open_ = [r for r in state.values() if r.get("event") == "failed"]
if not open_:
    print("fail: no unresolved failures")
else:
    print("unresolved failures: %d" % len(open_))
    for r in sorted(open_, key=lambda x: x.get("ts", "")):
        print("  %s  %s  %s" % (r.get("ts", "?"), r.get("cmd_hash", "?"), (r.get("cmd") or "")[:70]))
'
    ;;

  ""|-h|--help|help)
    sed -n '2,9p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \?//'
    ;;

  *) lab_die "unknown verb: $verb" ;;
esac
