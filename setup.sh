#!/bin/bash
# cc-bootstrap: AI development environment bootstrap
# Usage:
#   git clone https://github.com/Byun-jinyoung/cc-bootstrap.git ~/.cc-bootstrap
#   cd ~/.cc-bootstrap && ./setup.sh sync
#
# Subcommands:
#   sync      — Create/update symlinks from runtime dirs to this repo
#   doctor    — Check dependencies (system packages, Python libs, CLIs)
#   validate  — Validate skill frontmatter
#   update    — git pull → validate → sync → doctor
#   install   — Legacy copy-based install (environments where symlinks don't work)
#   init-project <path> — Initialize per-project settings (Serena registration, .claude/settings.local.json)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="$HOME/.codex"
AGENTS_DIR="$HOME/.agents"
GEMINI_DIR="$HOME/.gemini"
WARNINGS=0
ERRORS=0
SERENA_CONFIG="$HOME/.serena/serena_config.yml"
SKIP_NETWORK=false
SUBCMD="${1:-sync}"
SUBCMD_ARG="${2:-}"

# Load secrets from .env if present (gitignored).
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --skip-network) SKIP_NETWORK=true ;;
  esac
done

# Logging
LOG_DIR="$HOME/.cc-bootstrap/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup_$(date +%Y%m%d_%H%M%S).log"
STEP_TIMEOUT=120  # seconds per step

# Shared helpers (log, timeout, link, MCP verify/cleanup, codex hooks,
# graphify project config, global rule assembly). Sourced AFTER globals.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

# cmd_sync (sync subcommand body — large, separated for readability)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sync.sh"

cmd_doctor() {
  echo "=== cc-bootstrap doctor ==="

  # Establish the same user-owned prefix the sync uses, so the diagnostics
  # below speak the same vocabulary as the install path.
  ensure_user_npm_prefix

  echo "[ npm prefix policy ]  (goal: keep MY tools out of world-readable system paths)"
  local _cur_prefix _cur_root _mode
  _cur_prefix="$(npm config get prefix 2>/dev/null)"
  _cur_root="$(npm root -g 2>/dev/null)"
  echo "  npm config get prefix: ${_cur_prefix:-<unset>}"
  echo "  npm root -g:           ${_cur_root:-<unset>}"
  echo "  USER_NPM_PREFIX:       $USER_NPM_PREFIX (sync writes here)"
  # Report actual permission on USER_NPM_PREFIX so reader can tell if isolation
  # is in effect. ensure_user_npm_prefix locks this to 0700; a different mode
  # means either (a) the dir pre-exists with looser perms, or (b) someone else
  # owns it (unusual).
  _mode="$(stat -c '%a' "$USER_NPM_PREFIX" 2>/dev/null || stat -f '%Lp' "$USER_NPM_PREFIX" 2>/dev/null)"
  echo "  USER_NPM_PREFIX mode:  ${_mode:-?}"
  if [ -n "$_mode" ] && [ "$_mode" != "700" ]; then
    echo "  [WARN] $USER_NPM_PREFIX is mode $_mode — other users on this host may be able"
    echo "         to list/read/exec your installed tools. Lock with: chmod 700 $USER_NPM_PREFIX"
    WARNINGS=$((WARNINGS+1))
  fi
  if [ -n "$_cur_prefix" ] && [[ "$_cur_prefix" != "$HOME"/* ]]; then
    echo "  [WARN] npm prefix is outside \$HOME ($_cur_prefix) — bare 'npm install -g'"
    echo "         would write into a shared/system path readable by other users."
    echo "         setup.sh sync overrides per-invocation, but other tools may not."
    WARNINGS=$((WARNINGS+1))
  fi
  # Check if codex-gemini-mcp / @openai/codex packages landed in a system path
  for p in /usr/lib/node_modules /usr/local/lib/node_modules /opt/homebrew/lib/node_modules; do
    [ "$p" = "$USER_NPM_PREFIX/lib/node_modules" ] && continue
    for pkg in @donghae0414/codex-gemini-mcp @openai/codex; do
      if [ -d "$p/$pkg" ]; then
        echo "  [WARN] $pkg installed under system path: $p/$pkg"
        echo "         Other users on this host can read its contents. Re-run"
        echo "         'setup.sh sync' to reinstall into $USER_NPM_PREFIX, then remove"
        echo "         the system copy: npm uninstall -g --prefix ${p%/lib/node_modules} $pkg"
        WARNINGS=$((WARNINGS+1))
      fi
    done
  done
  for sym in /usr/bin/codex /usr/bin/codex-mcp /usr/bin/antigravity-mcp \
             /usr/local/bin/codex /usr/local/bin/codex-mcp /usr/local/bin/antigravity-mcp /usr/local/bin/gemini-mcp; do
    if [ -e "$sym" ] || [ -L "$sym" ]; then
      echo "  [WARN] $sym present (system path) — readable/executable by other users."
      echo "         If owned by this user, remove with: rm $sym  (otherwise: sudo rm $sym)"
      WARNINGS=$((WARNINGS+1))
    fi
  done
  echo ""

  echo "[ Credential / state dir permissions ]  (goal: only owner can read tokens/sessions)"
  for d in "$HOME/.codex" "$HOME/.gemini" "$HOME/.claude" "$HOME/.config/codex"; do
    if [ -d "$d" ]; then
      _mode="$(stat -c '%a' "$d" 2>/dev/null || stat -f '%Lp' "$d" 2>/dev/null)"
      if [ -n "$_mode" ] && [ "$_mode" != "700" ]; then
        echo "  [WARN] $d  mode=$_mode  (other users may read tokens/sessions)"
        echo "         Lock manually: chmod 700 $d   (setup.sh does NOT auto-chmod user state)"
        WARNINGS=$((WARNINGS+1))
      else
        echo "  [OK]   $d  mode=$_mode"
      fi
    fi
  done
  echo ""

  echo "[ CLI tools ]"
  for cmd in git node npm python3 uv claude codex gemini rtk graphify context-mode playwright; do
    if command -v $cmd &>/dev/null; then echo "  [OK] $cmd"
    else echo "  [MISS] $cmd"; WARNINGS=$((WARNINGS+1)); fi
  done

  echo ""
  echo "[ Symlinks ]"
  for f in "$CONFIG_DIR/commands/analyze-paper.md" \
    "$CODEX_DIR/instructions.md" "$GEMINI_DIR/GEMINI.md"; do
    if [ -L "$f" ] || [ -f "$f" ]; then echo "  [OK] $(basename "$f")"
    else echo "  [MISS] $f"; WARNINGS=$((WARNINGS+1)); fi
  done

  echo ""
  echo "[ Plugins ]"
  if command -v claude &>/dev/null; then
    for p in "octo@nyldn" "claude-mem@thedotmack" "ouroboros@ouroboros" "document-skills@anthropic" "oh-my-claudecode" "context-mode@context-mode" "codex@openai-codex"; do
      if claude plugin list 2>/dev/null | grep -q "$p"; then echo "  [OK] $p"
      else echo "  [MISS] $p"; WARNINGS=$((WARNINGS+1)); fi
    done
  fi

  echo ""
  echo "[ MCP servers (Claude) ]"
  if command -v claude &>/dev/null; then
    for m in codex-mcp antigravity-mcp serena supermemory; do
      if claude mcp list 2>/dev/null | grep -qE "$m.*(Connected|Needs authentication)"; then echo "  [OK] $m"
      else echo "  [MISS] $m"; WARNINGS=$((WARNINGS+1)); fi
    done
    # Detect stale gemini-mcp entry (fork no longer provides it)
    if claude mcp list 2>/dev/null | grep -qE '^gemini-mcp\b|^gemini-mcp\s'; then
      echo "  [STALE] gemini-mcp registered but fork dropped this bin — run 'setup.sh sync' to clean"
      WARNINGS=$((WARNINGS+1))
    fi
  fi

  echo ""
  echo "[ codex-gemini-mcp integrity (Byun-jinyoung fork) ]"
  if verify_codex_gemini_mcp; then
    entry_path="$(readlink -f "$(command -v codex-mcp 2>/dev/null)" 2>/dev/null)"
    echo "  [OK] fork features present (codex session_id, antigravity --conversation)"
    echo "        resolved: ${entry_path:-?}"
  else
    echo "  [FAIL] fork not installed (or upstream donghae0414 shadowing) — run 'setup.sh sync' to repair"
    WARNINGS=$((WARNINGS+1))
  fi
  # Detect upstream package layered anywhere (npm prefix or system).
  # Cover: user prefix used by this script, npm-configured prefix, both Homebrew
  # roots (Intel /usr/local + Apple Silicon /opt/homebrew), legacy system path,
  # and the literal ~/.npm-global fallback. De-dup via realpath.
  local _doctor_libs=() _root _libdir _libreal _dup _existing _tgt
  for _root in \
    "${USER_NPM_PREFIX:-}" \
    "$(npm config get prefix 2>/dev/null)" \
    /usr /usr/local /opt/homebrew \
    "$HOME/.npm-global"; do
    [ -n "$_root" ] || continue
    _libdir="$_root/lib/node_modules"
    [ -d "$_libdir" ] || continue
    _libreal="$(readlink -f "$_libdir" 2>/dev/null || echo "$_libdir")"
    _dup=0
    for _existing in "${_doctor_libs[@]}"; do
      [ "$_existing" = "$_libreal" ] && _dup=1 && break
    done
    [ "$_dup" = "1" ] && continue
    _doctor_libs+=("$_libreal")
    if [ -f "$_libreal/@donghae0414/codex-gemini-mcp/dist/providers/gemini.js" ]; then
      echo "  [WARN] upstream donghae0414 package present at $_libreal/@donghae0414/codex-gemini-mcp"
      WARNINGS=$((WARNINGS+1))
    fi
  done
  for sym in /usr/bin/codex-mcp /usr/bin/gemini-mcp /usr/local/bin/codex-mcp /usr/local/bin/gemini-mcp /usr/local/bin/antigravity-mcp; do
    if [ -L "$sym" ]; then
      _tgt="$(readlink -f "$sym" 2>/dev/null)"
      # Only warn if it points outside the user prefix (i.e., a stale legacy install)
      if [ -z "$_tgt" ] || [[ "$_tgt" != "${USER_NPM_PREFIX:-/__none__}"/* ]]; then
        echo "  [WARN] legacy system symlink $sym → ${_tgt:-<dangling>}"
        echo "         Remove: sudo rm $sym"
        WARNINGS=$((WARNINGS+1))
      fi
    fi
  done
  for bin in codex-mcp antigravity-mcp; do
    if mcp_spawn_check "$bin"; then
      echo "  [OK] $bin stdio handshake"
    else
      echo "  [FAIL] $bin stdio spawn — check exec bit / runtime deps"
      WARNINGS=$((WARNINGS+1))
    fi
  done
  # codex CLI scan — surface ALL installs (deterministic policy: exactly one)
  _doctor_cands=()
  for _seg in "$(npm config get prefix 2>/dev/null)/bin" "$HOME/.npm-global/bin" /usr/local/bin /opt/homebrew/bin /usr/bin; do
    if [ -x "$_seg/codex" ]; then
      _resolved="$(readlink -f "$_seg/codex" 2>/dev/null || echo "$_seg/codex")"
      _dup=0
      for _existing in "${_doctor_cands[@]}"; do
        [ "$(readlink -f "$_existing" 2>/dev/null || echo "$_existing")" = "$_resolved" ] && _dup=1 && break
      done
      [ "$_dup" = "1" ] || _doctor_cands+=("$_seg/codex")
    fi
  done
  if [ "${#_doctor_cands[@]}" -eq 0 ]; then
    echo "  [FAIL] codex CLI missing — install: npm i -g @openai/codex"
    WARNINGS=$((WARNINGS+1))
  elif [ "${#_doctor_cands[@]}" -eq 1 ]; then
    if command -v codex &>/dev/null; then
      echo "  [OK] codex CLI on PATH (${_doctor_cands[0]})"
    else
      echo "  [OK] codex CLI at ${_doctor_cands[0]} (not on live PATH; codex-mcp PATH env will resolve it)"
    fi
  else
    echo "  [WARN] multiple codex installs (non-deterministic):"
    for _existing in "${_doctor_cands[@]}"; do
      echo "          • $_existing → $(readlink -f "$_existing" 2>/dev/null || echo "$_existing")"
    done
    command -v codex &>/dev/null && echo "          PATH winner: $(command -v codex)"
    echo "          Keep one (recommended: \$(npm config get prefix)/bin/codex); remove rest."
    WARNINGS=$((WARNINGS+1))
  fi

  echo ""
  echo "[ MCP servers (Codex/Antigravity for triangle-review) ]"
  if [ -f "$CODEX_DIR/config.toml" ] && grep -qF "multi_agent = true" "$CODEX_DIR/config.toml"; then
    echo "  [OK] codex multi_agent"
  else
    echo "  [MISS] codex multi_agent (run setup.sh sync)"
    WARNINGS=$((WARNINGS+1))
  fi
  for entry in "$CODEX_DIR/config.toml:[mcp_servers.serena]:codex serena" \
               "$CODEX_DIR/config.toml:[mcp_servers.code-review-graph]:codex code-review-graph" \
               "$CODEX_DIR/config.toml:[mcp_servers.context-mode]:codex context-mode"; do
    file="${entry%%:*}"
    rest="${entry#*:}"
    pat="${rest%%:*}"
    label="${rest#*:}"
    if [ -f "$file" ] && grep -qF "$pat" "$file"; then echo "  [OK] $label"
    else echo "  [MISS] $label (run setup.sh sync)"; WARNINGS=$((WARNINGS+1)); fi
  done
  # Antigravity MCP check — primary location is ~/.gemini/config/mcp_config.json
  # (read by agy CLI and Antigravity IDE). The pre-2026-05-19 top-level
  # ~/.gemini/settings.json is checked too as a transition guard: stale
  # entries there are reported as WARN so users know to migrate.
  if command -v python3 &>/dev/null; then
    python3 - "$GEMINI_DIR/config/mcp_config.json" "$GEMINI_DIR/settings.json" << 'PYEOF'
import json, sys
from pathlib import Path

shared = Path(sys.argv[1])
legacy = Path(sys.argv[2])

shared_servers = {}
if shared.exists() and shared.stat().st_size > 0:
    try:
        shared_servers = json.loads(shared.read_text()).get("mcpServers", {})
    except Exception as e:
        print(f"  [WARN] {shared} unparseable: {e}")

for name in ("serena", "code-review-graph"):
    if name in shared_servers: print(f"  [OK] antigravity {name}")
    else: print(f"  [MISS] antigravity {name} (expected in config/mcp_config.json — run setup.sh sync)")

# Legacy location: warn if old gemini-cli settings.json still has mcpServers
if legacy.exists():
    try:
        legacy_servers = json.loads(legacy.read_text()).get("mcpServers", {})
        if legacy_servers:
            stale = ", ".join(sorted(legacy_servers.keys()))
            print(f"  [WARN] stale mcpServers in {legacy.name}: {stale} — agy ignores these. Run setup.sh sync to migrate.")
    except Exception:
        pass
PYEOF
  fi
  if [ -f "$CODEX_DIR/hooks.json" ] && grep -qF "context-mode hook codex pretooluse" "$CODEX_DIR/hooks.json" \
    && grep -qF "context-mode hook codex posttooluse" "$CODEX_DIR/hooks.json" \
    && grep -qF "context-mode hook codex sessionstart" "$CODEX_DIR/hooks.json" \
    && grep -qF "context-mode hook codex userpromptsubmit" "$CODEX_DIR/hooks.json" \
    && grep -qF "context-mode hook codex stop" "$CODEX_DIR/hooks.json"; then
    echo "  [OK] codex context-mode hooks"
  else
    echo "  [MISS] codex context-mode hooks (run setup.sh sync)"
    WARNINGS=$((WARNINGS+1))
  fi
  if [ -f "$CODEX_DIR/AGENTS.md" ] && grep -qF "context-mode" "$CODEX_DIR/AGENTS.md"; then
    echo "  [OK] codex context-mode routing instructions"
  else
    echo "  [MISS] codex context-mode routing instructions (run setup.sh sync)"
    WARNINGS=$((WARNINGS+1))
  fi

  echo ""
  echo "[ Managed skills ]"
  # graphify is checked separately below (CLI-owned, not a cc-bootstrap symlink).
  for sk in triangle-review codebase-scan; do
    src="$SCRIPT_DIR/skills/$sk"
    dst="$CONFIG_DIR/skills/$sk"
    if [ -L "$dst" ] && [ -e "$dst" ]; then echo "  [OK] $sk symlink"
    elif [ -e "$dst" ]; then echo "  [WARN] $sk exists but not symlinked from cc-bootstrap"
    else echo "  [MISS] $sk"; WARNINGS=$((WARNINGS+1)); fi
  done
  # graphify is managed by the graphify CLI itself (not cc-bootstrap).
  # claude side = real dir with SKILL.md; agents side = symlink to it.
  if [ -f "$CONFIG_DIR/skills/graphify/SKILL.md" ]; then echo "  [OK] graphify claude SKILL"
  else echo "  [MISS] graphify claude SKILL (run: graphify install --platform claude)"; WARNINGS=$((WARNINGS+1)); fi
  if [ -L "$AGENTS_DIR/skills/graphify" ] \
     && [ "$(readlink "$AGENTS_DIR/skills/graphify")" = "$CONFIG_DIR/skills/graphify" ]; then
    echo "  [OK] graphify agents mirror"
  else echo "  [WARN] graphify agents mirror missing (rerun setup.sh sync)"; WARNINGS=$((WARNINGS+1)); fi
  if command -v code-review-graph &>/dev/null; then echo "  [OK] code-review-graph CLI"
  else echo "  [MISS] code-review-graph CLI (pip install code-review-graph)"; WARNINGS=$((WARNINGS+1)); fi
  if command -v graphify &>/dev/null; then echo "  [OK] graphify CLI"
  else echo "  [MISS] graphify CLI (uv tool install graphifyy)"; WARNINGS=$((WARNINGS+1)); fi

  echo ""
  echo "[ Frameworks ]"
  if ls "$CONFIG_DIR/commands/gsd"* &>/dev/null 2>&1 || ls -d "$CONFIG_DIR/skills/gsd-"* &>/dev/null 2>&1; then
    echo "  [OK] GSD ($(ls -d "$CONFIG_DIR/skills/gsd-"* 2>/dev/null | wc -l) skills)"
  else echo "  [MISS] GSD"; WARNINGS=$((WARNINGS+1)); fi
  if command -v rtk &>/dev/null; then
    echo "  [OK] RTK $(rtk --version 2>/dev/null)"
    # Current rtk hook pattern (rtk >= 0.38, also installed by older versions):
    #   PreToolUse[Bash] -> { "command": "rtk hook claude" }
    # The pre-0.38 `rtk-rewrite.sh` shell-script form is legacy.
    if grep -q 'rtk hook claude' "$CONFIG_DIR/settings.json" 2>/dev/null; then
      echo "  [OK] RTK hook active in settings.json"
      if grep -q 'rtk-rewrite\.sh' "$CONFIG_DIR/settings.json" 2>/dev/null; then
        echo "  [WARN] legacy 'rtk-rewrite.sh' entry also present — run 'setup.sh sync' to strip"
        WARNINGS=$((WARNINGS+1))
      fi
    else
      echo "  [FAIL] RTK hook NOT in settings.json — run 'setup.sh sync'"
      WARNINGS=$((WARNINGS+1))
    fi
  else
    echo "  [MISS] RTK"; WARNINGS=$((WARNINGS+1))
  fi

  echo ""
  [ $WARNINGS -gt 0 ] && echo "  $WARNINGS item(s) missing." || echo "  All checks passed."
}

cmd_validate() {
  echo "=== cc-bootstrap validate ==="
  for skill_dir in "$SCRIPT_DIR/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "$skill_dir")"
    found=false
    [ -f "$skill_dir/SKILL.md" ] && found=true
    for sub in "$skill_dir"*/SKILL.md; do [ -f "$sub" ] && found=true && break; done
    $found && echo "  [OK] $name" || echo "  [FAIL] $name: no SKILL.md"
  done
  for f in "$SCRIPT_DIR/runtimes/claude/commands/"*.md; do
    [ -f "$f" ] || continue
    head -5 "$f" | grep -q "description:" && echo "  [OK] $(basename "$f")" || echo "  [WARN] $(basename "$f"): no description"
  done
}

cmd_update() {
  echo "=== cc-bootstrap update ==="
  echo "[1/4] git pull"
  git -C "$SCRIPT_DIR" pull --ff-only 2>&1 | sed 's/^/  /'
  echo "[2/4] validate" && cmd_validate
  echo "[3/4] sync" && cmd_sync
  echo "[4/4] doctor" && cmd_doctor
}

cmd_install() {
  echo "=== cc-bootstrap install (legacy copy mode) ==="
  mkdir -p "$CONFIG_DIR/commands" "$CONFIG_DIR/hud" "$CODEX_DIR" "$GEMINI_DIR"
  cp "$SCRIPT_DIR/runtimes/claude/commands/"*.md "$CONFIG_DIR/commands/" 2>/dev/null || true
  cp "$SCRIPT_DIR/runtimes/codex/instructions.md" "$CODEX_DIR/" 2>/dev/null || true
  cp "$SCRIPT_DIR/ui/statusline/my-statusline.mjs" "$CONFIG_DIR/hud/" 2>/dev/null || true
  # Global rule files (Layer A + Layer B) for Claude/Codex/Gemini
  assemble_global_rules
  for rt in claude codex agents gemini; do
    for sd in "$SCRIPT_DIR/skills/"*/; do
      dst_base="$HOME/.$rt/skills"
      [ "$rt" = "claude" ] && dst_base="$CONFIG_DIR/skills"
      if [ -d "$sd/$rt" ]; then
        mkdir -p "$dst_base/$(basename "$sd")" && cp "$sd/$rt/"* "$dst_base/$(basename "$sd")/" 2>/dev/null
      elif [ -f "$sd/SKILL.md" ] && { [ "$rt" = "claude" ] || [ "$rt" = "agents" ]; }; then
        mkdir -p "$dst_base/$(basename "$sd")" && cp "$sd/SKILL.md" "$dst_base/$(basename "$sd")/SKILL.md" 2>/dev/null
      fi
    done
  done
  echo "  Legacy install complete."
}

cmd_init_project() {
  local project_path="$1"
  if [ -z "$project_path" ]; then
    echo "Usage: ./setup.sh init-project <path>"
    echo "  Example: ./setup.sh init-project ~/PROject/boltz2"
    exit 1
  fi

  # Resolve to absolute path
  project_path="$(cd "$project_path" 2>/dev/null && pwd)" || {
    echo "[FAIL] Directory not found: $1"
    exit 1
  }
  local project_name="$(basename "$project_path")"
  echo "=== cc-bootstrap init-project: $project_name ==="
  echo "  Path: $project_path"
  echo ""

  # [1] Register with Serena
  echo "[1] Serena project registration"
  if [ -f "$SERENA_CONFIG" ]; then
    if grep -q "$project_path" "$SERENA_CONFIG" 2>/dev/null; then
      echo "    [OK] Already registered in serena_config.yml"
    else
      # Append project path to projects list
      python3 << PYEOF
import sys
try:
    import yaml
except ImportError:
    print("    [WARN] PyYAML missing. pip install pyyaml")
    sys.exit(0)

with open("$SERENA_CONFIG") as f:
    config = yaml.safe_load(f) or {}

projects = config.get("projects", []) or []
if "$project_path" not in projects:
    projects.append("$project_path")
    config["projects"] = projects
    with open("$SERENA_CONFIG", "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    print("    [OK] Registered: $project_path")
else:
    print("    [OK] Already registered")
PYEOF
    fi
  else
    echo "    [SKIP] ~/.serena/serena_config.yml not found (Serena not installed?)"
  fi

  # [2] Create project .serena directory
  echo "[2] Serena project data directory"
  if [ -d "$project_path/.serena" ]; then
    echo "    [OK] $project_path/.serena/ already exists"
  else
    mkdir -p "$project_path/.serena"
    echo "    [OK] Created $project_path/.serena/"
  fi

  # [3] Create .claude/settings.local.json if not exists
  echo "[3] Claude Code project settings"
  local claude_project_dir="$project_path/.claude"
  local settings_local="$claude_project_dir/settings.local.json"
  if [ -f "$settings_local" ]; then
    echo "    [OK] $settings_local already exists"
  else
    mkdir -p "$claude_project_dir"
    cat > "$settings_local" << JSONEOF
{
  "permissions": {},
  "env": {}
}
JSONEOF
    echo "    [OK] Created $settings_local"
  fi

  # [4] Create project CLAUDE.md if not exists
  echo "[4] Project CLAUDE.md"
  if [ -f "$project_path/CLAUDE.md" ]; then
    echo "    [OK] CLAUDE.md already exists"
  else
    cat > "$project_path/CLAUDE.md" << MDEOF
# $project_name

## 기술 스택

| 분류 | 도구 |
|------|------|
| **프레임워크** | |
| **Type Hints** | jaxtyping (필수) |
| **Docstring** | Google style |

## 작업 규칙

### 금지 사항
- 불확실한 내용을 추측으로 답변하지 마세요
- 파일을 읽지 않고 코드에 대해 가정하지 마세요
- 질문 없이 애매한 요구사항을 임의로 해석하지 마세요
MDEOF
    echo "    [OK] Created CLAUDE.md (edit to customize)"
  fi

  # [5] Add .serena to .gitignore if not already
  echo "[5] .gitignore"
  if [ -f "$project_path/.gitignore" ]; then
    if grep -q "^\.serena" "$project_path/.gitignore" 2>/dev/null; then
      echo "    [OK] .serena already in .gitignore"
    else
      echo ".serena/" >> "$project_path/.gitignore"
      echo "    [OK] Added .serena/ to .gitignore"
    fi
  else
    echo ".serena/" > "$project_path/.gitignore"
    echo "    [OK] Created .gitignore with .serena/"
  fi

  write_graphify_project_config "$project_path"

  echo ""
  echo "=== init-project complete: $project_name ==="
  echo "  Next: cd $project_path && claude"
}

case "$SUBCMD" in
  sync) cmd_sync ;; doctor) cmd_doctor ;; validate) cmd_validate ;;
  update) cmd_update ;; install) cmd_install ;;
  init-project) cmd_init_project "$SUBCMD_ARG" ;;
  *) echo "Usage: ./setup.sh {sync|doctor|validate|update|install|init-project <path>}"; exit 1 ;;
esac
