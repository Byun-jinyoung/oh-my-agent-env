#!/usr/bin/env bash
# PreCompact gate — defer auto-compaction to a work-unit boundary.
#
#   defer (exit 2)  : trigger=auto AND fresh busy marker AND tokens < ceiling
#                     AND this session still has defer budget
#   allow (exit 0)  : anything else  (stdout = summary instructions)
#
# Rationale: blocking compaction unconditionally kills the session with
# "Prompt is too long" (measured). Every failure path here therefore ALLOWS.
#
# MEASURED CONSTRAINT (v2.1.220): after ~4 consecutive blocked attempts the
# runtime stops evaluating autocompact for the rest of the session — the hook is
# never called again, so a token ceiling alone CANNOT rescue it. The gate must
# therefore spend its own budget: defer at most COMPACT_MAX_DEFERS times in a
# row, then allow while the runtime is still willing to retry.
#
# That runtime budget is PER SESSION, so the defer count is tallied per
# session_id — not per marker. A second session in the same directory used to
# reset the shared count and could walk this session into the runtime's
# give-up state.
#
# Marker staleness: a marker left behind by a crashed session (SessionEnd hook
# never ran) would otherwise defer forever. Markers older than
# COMPACT_MARKER_TTL_MIN are deleted and ignored. `compact-gate busy` re-run
# refreshes the marker, so an active work unit never expires.
#
# stdin (verified v2.1.220): {session_id, transcript_path, cwd, prompt_id,
#                             hook_event_name, trigger, custom_instructions}
# stdout on allow: plain text -> becomes newCustomInstructions for the summary.

set -u

CEILING="${COMPACT_HARD_CEILING:-550000}"
MAX_DEFERS="${COMPACT_MAX_DEFERS:-2}"      # keep < the runtime's ~4-attempt budget
TTL_MIN="${COMPACT_MARKER_TTL_MIN:-90}"    # minutes before a busy marker goes stale
GATE_DIR="${COMPACT_GATE_DIR:-$HOME/.claude/compact-gate}"
LOG="$GATE_DIR/gate.log"
LOG_MAX_LINES="${COMPACT_LOG_MAX_LINES:-2000}"
LOG_KEEP_LINES="${COMPACT_LOG_KEEP_LINES:-500}"

read -r -d '' ALLOW_INSTRUCTIONS <<'EOF' || true
전체 프로젝트 목표 및 단계별 작업 위주로 요약하라.

## 요약 구조
- **프로젝트 최종 목표**: 전체 프로젝트가 달성하려는 최종 목표를 한 문장으로 명시하라
- **현재 세션 목표**: 이번 세션에서 구체적으로 달성하려는 목표를 명시하라
- **완료된 작업**: 완료한 작업을 단계별로 나열하되, 각 단계의 핵심 결과만 포함하라
- **현재 진행 중인 작업**: 다음을 포함하라
  - 수행 중이거나 중단된 작업과 진행률
  - 마지막 작업 지점 (파일명, 함수명, 코드 위치 등 구체적으로)
  - 다음 즉시 수행할 단계 (재개 시 바로 해야 할 구체적 행동)
- **차단된 작업/실패 사례**: 시도했으나 실패하거나 보류된 작업과 그 이유를 기록하라
- **남은 작업**: 앞으로 수행해야 할 작업을 우선순위 순으로 나열하라
- **주요 결정 사항 및 근거**: 작업 중 내린 중요한 기술적 결정과 그 이유를 기록하라

## 포함 사항
- 프로젝트/세션 목표, 단계별 작업 상태, 주요 기술적 결정
- **핵심 작업 파일 목록** (전체 경로 아닌 상대 경로)
- 발견된 이슈 및 차단 사항
- 실행한 검증 명령과 그 출력, 확정된 결정과 근거

## 제외 사항
- 상세한 코드 내용, 시행착오 과정, 중복된 설명
- 관련 없는 파일 경로

## 형식
- 계층적 구조(대분류 → 중분류 → 소분류)로 정리하라
- 각 항목은 1-2문장으로 간결하게 작성하라
- 시간 순서보다 논리적 흐름에 따라 정리하라
EOF

mkdir -p "$GATE_DIR" 2>/dev/null

payload=$(cat)

# ---- parse stdin ------------------------------------------------------------
# Tab-separated so an empty field can never shift the others.
IFS=$'\t' read -r cwd transcript sid trigger < <(
  printf '%s' "$payload" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    f=lambda k:(str(d.get(k) or "-").replace("\t"," ").replace("\n"," ") or "-")
    print("\t".join([f("cwd"),f("transcript_path"),f("session_id"),f("trigger")]))
except Exception:
    print("\t".join(["-","-","-","-"]))
' 2>/dev/null
) || { cwd="-"; transcript="-"; sid="-"; trigger="-"; }
: "${cwd:=-}" "${transcript:=-}" "${sid:=-}" "${trigger:=-}"

# Marker path: cwd slug + session id. Keying on cwd alone made two sessions in
# one directory share a marker, so a SessionEnd in either wiped a work unit the
# other was still inside — measured, and it silently disables the gate.
# `-` (unparseable stdin) degrades to the cwd-only path both scripts used before.
slug=$(printf '%s' "$cwd" | tr -c 'A-Za-z0-9' '-')
if [ "$sid" != "-" ]; then
  marker="$GATE_DIR/${slug}.${sid}.busy"
else
  marker="$GATE_DIR/${slug}.busy"
fi

# ---- log rotation (bounded scan cost, bounded disk) -------------------------
if [ -f "$LOG" ]; then
  lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  if [ "${lines:-0}" -gt "$LOG_MAX_LINES" ] 2>/dev/null; then
    tail -n "$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null &&
      mv -f "$LOG.tmp" "$LOG" 2>/dev/null
  fi
fi

log() { printf '%s gate=%s sid=%s tokens=%s ceiling=%s marker=%s\n' \
        "$(date -Is)" "$1" "$sid" "${2:--}" "$CEILING" "$marker" >> "$LOG" 2>/dev/null; }

allow() { log "ALLOW:$1" "${2:--}"; printf '%s\n' "$ALLOW_INSTRUCTIONS"; exit 0; }

# ---- tier 0: only auto-compaction is ours to defer ---------------------------
# Distinguish the two non-auto cases. Folding them together logged an
# unparseable payload as `manual-trigger`, which reads as a user action.
case "$trigger" in
  auto)    : ;;
  manual)  allow "manual-trigger" ;;
  *)       allow "stdin-parse-failed(trigger=$trigger)" ;;
esac

# ---- tier 1: no work unit in progress -> allow ------------------------------
[ -f "$marker" ] || allow "no-marker"

# ---- tier 1b: stale marker (crashed session, missed `done`) -> allow --------
# fail-open: if the marker age cannot be read, treat it as stale.
mtime=$(stat -c %Y "$marker" 2>/dev/null) || mtime=""
now=$(date +%s)
if [ -z "$mtime" ]; then
  rm -f "$marker" 2>/dev/null
  allow "marker-age-unknown"
fi
age_min=$(( (now - mtime) / 60 ))
if [ "$age_min" -ge "$TTL_MIN" ] 2>/dev/null; then
  rm -f "$marker" 2>/dev/null
  allow "marker-stale(${age_min}m>=${TTL_MIN}m)"
fi

# ---- tier 2: hard ceiling -> allow regardless of marker ---------------------
tokens=$(python3 - "$transcript" <<'PY' 2>/dev/null
import json,os,sys
p=sys.argv[1]
if p in ("-","") or not os.path.isfile(p):
    print(-1); raise SystemExit
try:
    size=os.path.getsize(p)
    with open(p,"rb") as f:                      # tail-read: transcripts get huge
        f.seek(max(0,size-1_000_000))
        lines=f.read().split(b"\n")
    best=-1
    for raw in reversed(lines):
        if not raw.strip():
            continue
        try:
            u=(json.loads(raw).get("message") or {}).get("usage") or {}
        except Exception:
            continue
        if u:
            best=(u.get("input_tokens",0) + u.get("cache_read_input_tokens",0)
                  + u.get("cache_creation_input_tokens",0))
            break
    print(best)
except Exception:
    print(-1)
PY
)
[ -n "${tokens:-}" ] || tokens=-1

# unknown token count -> fail open
[ "$tokens" -lt 0 ] 2>/dev/null && allow "tokens-unknown" "$tokens"
[ "$tokens" -ge "$CEILING" ] 2>/dev/null && allow "ceiling-reached" "$tokens"

# ---- tier 3: consecutive-defer budget, tallied PER SESSION ------------------
# The runtime's give-up budget is per session, so another session sharing this
# directory must not reset (or inflate) this session's count.
defers=0
if [ -f "$LOG" ] && [ "$sid" != "-" ]; then
  defers=$(awk -v key=" sid=$sid " '
    index($0,key) {
      if ($0 ~ /gate=ALLOW/) n=0;
      else if ($0 ~ /gate=DEFER/) n++;
    }
    END { print n+0 }
  ' "$LOG" 2>/dev/null)
fi
[ -n "${defers:-}" ] || defers=0

if [ "$defers" -ge "$MAX_DEFERS" ] 2>/dev/null; then
  allow "defer-budget-spent($defers/$MAX_DEFERS)" "$tokens"
fi

# ---- defer ------------------------------------------------------------------
log "DEFER" "$tokens"
echo "work unit in progress (${tokens} tok < ${CEILING}, defer $((defers+1))/${MAX_DEFERS}); deferring compaction to a task boundary" >&2
exit 2
