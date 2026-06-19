#!/usr/bin/env bash
# diagnose-codex-context-mode.sh
# ---------------------------------------------------------------------------
# 목적: "codex에서 context-mode가 안 된다" 증상의 근본원인을 H1/H2/H3로 가린다.
#   H1 = context-mode MCP 서버 미기동 (codex 상속 PATH에 bin 없음)
#   H2 = context-mode 미설치 / 실행 불가
#   H3 = MCP는 뜨지만 context-mode hook 미발화
#
# 배경(근거): ensure_codex_context_mode(lib/common.sh)는 codex에 context-mode를
#   `command = "context-mode"` (config.toml) + bare `context-mode hook codex …`
#   (hooks.json) 로 등록한다 — PATH env 미주입. codex npm wrapper(codex.js)는
#   login-shell PATH를 만들지 않고 부모 프로세스 PATH만 상속시키므로, 비로그인/
#   데스크톱/systemd/원격 환경에서 ~/.npm-global/bin 이 PATH에 없으면 ENOENT.
#
# 주의: `context-mode`는 인자 없이/미인식 플래그로 실행하면 버전만 찍고 끝나는
#   게 아니라 MCP 서버를 띄우고 stdio에서 블로킹한다. 그래서 이 스크립트는
#   바이너리를 직접 실행하지 않고(또는 timeout+</dev/null로 감싸고), 버전은
#   npm 메타데이터로 확인한다.
#
# 사용법: 문제가 나는 (리눅스) 머신에서 그대로 실행하고 출력 전체를 공유.
#   bash diagnose-codex-context-mode.sh
# 읽기 전용 — 아무것도 수정하지 않는다.
# ---------------------------------------------------------------------------
set -u

line() { printf '\n===== %s =====\n' "$1"; }

# 블로킹 가능 명령용 안전 실행기: timeout 있으면 적용, 항상 stdin은 /dev/null.
run() {  # run <secs> <cmd...>
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}s" "$@" </dev/null 2>&1
  else
    "$@" </dev/null 2>&1
  fi
}

line "[0] 기본 환경"
echo "DATE=$(date '+%F %T')"
echo "UNAME=$(uname -srm)"
echo "SHELL=$SHELL"
echo "PATH=$PATH"
echo "timeout available: $(command -v timeout >/dev/null 2>&1 && echo yes || echo NO)"

line "[1] 설치/PATH (H2 배제용)  — 바이너리 직접 실행 안 함(서버 기동·블로킹 방지)"
echo "codex bin:        $(command -v codex 2>/dev/null || echo MISSING)"
run 10 codex --version | head -1 || true
echo "context-mode bin: $(command -v context-mode 2>/dev/null || echo 'NOT on PATH')"
ctx="$(command -v context-mode 2>/dev/null || true)"
[ -n "$ctx" ] && ls -l "$ctx"
echo "context-mode 버전(npm 메타, 비블로킹): $(npm ls -g context-mode 2>/dev/null | grep context-mode || echo '?')"
echo "npm prefix -g: $(npm config get prefix 2>/dev/null || echo '?')"
echo "npm root -g:   $(npm root -g 2>/dev/null || echo '?')"

line "[2] codex MCP 등록 상태 (H1)"
run 15 codex mcp get context-mode | head -25 || true
echo "--- codex mcp list (context-mode 행) ---"
run 15 codex mcp list | grep -iE 'context-mode|name|command|env' | head -10 || true

line "[3] config.toml / hooks.json 실내용"
python3 - <<'PY' 2>/dev/null || echo "(python3 미가용 — config/hooks 수동 확인 필요)"
import json, re, pathlib
home = pathlib.Path.home()
cfg = home / ".codex/config.toml"
hooks = home / ".codex/hooks.json"
print("-- config [mcp_servers.context-mode] --")
if cfg.exists():
    m = re.search(r'(?ms)^\[mcp_servers\.context-mode\].*?(?=^\[|\Z)', cfg.read_text())
    print(m.group(0).strip() if m else "NO context-mode block")
else:
    print("NO config.toml")
print("-- hooks.json: context-mode hook 항목 --")
if hooks.exists():
    data = json.loads(hooks.read_text())
    n = 0
    for ev, arr in (data.get("hooks") or {}).items():
        if isinstance(arr, list):
            for x in arr:
                if "context-mode hook codex" in json.dumps(x):
                    n += 1
                    print(ev, "->", json.dumps(x, ensure_ascii=False))
    print(f"(총 {n} hook entries)")
else:
    print("NO hooks.json")
PY

line "[4] 최소 PATH 재현 (codex가 보는 축소 환경 모사)"
# codex가 비로그인/데스크톱 환경에서 받을 법한 축소 PATH에서 context-mode bin이
# 해결되는지 확인. MISSING 이면 H1(상속 PATH 미해결)의 강한 신호.
# (실행이 아니라 resolution만 확인 — command -v 는 블로킹 없음)
env -i HOME="$HOME" PATH="/usr/local/bin:/usr/bin:/bin" sh -c \
  'if command -v context-mode >/dev/null 2>&1; then echo "FOUND in minimal PATH"; else echo "MISSING in minimal PATH  -> H1 신호"; fi'

line "[5] codex 로그 (MCP 기동 / hook 실패 흔적)"
logf="$(ls -t "$HOME"/.codex/log*/*.log "$HOME"/.codex/*.log 2>/dev/null | head -1)"
if [ -n "${logf:-}" ] && [ -f "$logf" ]; then
  echo "LOG=$logf"
  tail -n 600 "$logf" \
    | grep -iE 'context-mode|stdio_server_launcher|mcp_manager|hook_runtime|no such file|not found|command not found' \
    | tail -40 || echo "(관련 로그 라인 없음)"
else
  echo "(codex 로그 파일을 못 찾음 — ~/.codex/ 하위 로그 경로 확인 필요)"
fi

line "판정 가이드"
cat <<'EOF'
- [1]에서 context-mode가 "NOT on PATH" 또는 npm 메타에 없음   -> H2 (설치/PATH 문제)
- [1] 정상인데 [4]가 "MISSING in minimal PATH"                -> H1 강한 신호 (codex 축소 PATH 미해결)
- [5] 로그에 "stdio_server_launcher ... No such file"          -> H1 (MCP 미기동)
- [5] 로그에 "hook_runtime ... No such file"                   -> H3 (hook 미발화)
- 위 출력 전체를 공유하면 ensure_codex_context_mode(common.sh) 패치로
  모든 머신에 영구·멱등 수정 적용.
EOF
