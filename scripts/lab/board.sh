#!/usr/bin/env bash
# Claim an experiment id so two sessions cannot silently run the same thing.
#
#   oma-lab board claim  --id NAME [--hypothesis "..."]
#   oma-lab board start  --id NAME [--job SLURM_ID] [--run-id ID]
#   oma-lab board touch  --id NAME                 heartbeat for a long job
#   oma-lab board finish --id NAME --result "..." [--next "..."]
#   oma-lab board abort  --id NAME [--note "..."]
#   oma-lab board list | show --id NAME
#
# Append-only; current state is the last event for an id. A claim is refused
# while another claim is active, which is the whole point: the duplicate run
# an agent starts because it does not know another session already started it
# costs the same GPU hours as the original.
#
# A stale CLAIMED entry can be taken over after OMA_BOARD_CLAIM_TTL (default
# 1 day) — someone claimed it and wandered off. A RUNNING entry never expires:
# a training job legitimately outlives any session, and stealing its id would
# produce two jobs writing the same checkpoints.
set -uo pipefail

# shellcheck disable=SC1091
. "${LAB_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}/common.sh"

TTL="${OMA_BOARD_CLAIM_TTL:-86400}"
ID="" HYP="" JOB="" RESULT="" NEXT="" NOTE="" RUNID=""

verb="${1:-list}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --id|--hypothesis|--job|--result|--next|--note|--run-id|--repo)
      [ $# -ge 2 ] || lab_die "$1 needs a value"
      case "$1" in
        --id)         ID="$2" ;;
        --hypothesis) HYP="$2" ;;
        --job)        JOB="$2" ;;
        --result)     RESULT="$2" ;;
        --next)       NEXT="$2" ;;
        --note)       NOTE="$2" ;;
        --run-id)     RUNID="$2" ;;
        --repo)       LAB_ROOT="$(cd "$2" && pwd -P)" || lab_die "no such repo: $2"; export LAB_ROOT ;;
      esac
      shift 2 ;;
    *) lab_die "unknown option: $1" ;;
  esac
done

FILE="$(lab_experiments_path)"
OWNER="${USER:-unknown}"
need_id() { [ -n "$ID" ] || lab_die "$verb requires --id"; }

emit() {
  lab_append_jsonl "$FILE" "$(lab_json_obj \
    ts "$(lab_now)" epoch "$(date +%s)" event "$1" id "$ID" owner "$OWNER" \
    hypothesis "$HYP" job "$JOB" run_id "${RUNID:-$(lab_current_run_id || printf '')}" \
    result "$RESULT" next "$NEXT" note "$NOTE" repo "${LAB_ROOT:-$(lab_repo_root)}")"
}

case "$verb" in
  claim)
    need_id
    lab_jsonl_query "$FILE" '
wanted, now, ttl, me = args[0], int(args[1]), int(args[2]), args[3]
last = None
for r in rows:
    if r.get("id") == wanted: last = r
if last is None or last.get("event") in ("finished", "aborted"):
    sys.exit(0)
ev, owner, age = last.get("event"), last.get("owner", "?"), now - int(last.get("epoch") or 0)
if ev == "claimed" and age >= ttl:
    sys.stderr.write("board: taking over a claim stale for %dh (was %s)\n" % (age // 3600, owner))
    sys.exit(0)
sys.stderr.write(
    "board: %r is already %s by %s since %s.\n"
    "       Pick another id, or: oma-lab board abort --id %s\n"
    % (wanted, ev, owner, last.get("ts", "?"), wanted))
sys.exit(4)
' "$ID" "$(date +%s)" "$TTL" "$OWNER" || exit $?
    emit claimed
    printf 'board: claimed %s\n' "$ID"
    ;;

  start)  need_id; emit started;  printf 'board: started %s%s\n' "$ID" "${JOB:+ (job $JOB)}" ;;
  touch)  need_id; emit touched;  ;;
  finish) need_id; [ -n "$RESULT" ] || lab_die "finish requires --result"
          emit finished; printf 'board: finished %s\n' "$ID" ;;
  abort)  need_id; emit aborted;  printf 'board: aborted %s\n' "$ID" ;;

  list)
    lab_jsonl_query "$FILE" '
now, ttl = int(args[0]), int(args[1])
state = {}
for r in rows:
    if r.get("id"): state[r["id"]] = r
active = [r for r in state.values() if r.get("event") in ("claimed", "started", "touched")]
done   = [r for r in state.values() if r.get("event") in ("finished", "aborted")]
if active:
    print("active:")
    for r in sorted(active, key=lambda x: x.get("ts", "")):
        age = now - int(r.get("epoch") or 0)
        stale = " STALE" if r.get("event") == "claimed" and age > ttl else ""
        print("  %-24s %-8s %-10s %s%s" % (r.get("id"), r.get("event"), r.get("owner", "?"),
                                           r.get("hypothesis") or r.get("job") or "", stale))
else:
    print("active: none")
print("closed: %d" % len(done))
' "$(date +%s)" "$TTL"
    ;;

  show)
    need_id
    lab_jsonl_query "$FILE" '
wanted = args[0]
hits = [r for r in rows if r.get("id") == wanted]
if not hits:
    print("board: no such id: %s" % wanted); sys.exit(1)
for r in hits:
    extra = " | ".join(filter(None, [
        str(r.get("hypothesis") or ""), ("job=%s" % r["job"]) if r.get("job") else "",
        str(r.get("result") or ""), ("next: %s" % r["next"]) if r.get("next") else "",
        str(r.get("note") or "")]))
    print("%s  %-9s %-10s %s" % (r.get("ts", "?"), r.get("event"), r.get("owner", "?"), extra))
' "$ID"
    ;;

  ""|-h|--help|help)
    sed -n '2,10p' "$(readlink -f "${BASH_SOURCE[0]}")" | sed 's/^# \?//'
    ;;

  *) lab_die "unknown verb: $verb" ;;
esac
