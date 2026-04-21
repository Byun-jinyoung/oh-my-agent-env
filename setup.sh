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
GEMINI_DIR="$HOME/.gemini"
WARNINGS=0
ERRORS=0
SERENA_CONFIG="$HOME/.serena/serena_config.yml"
SKIP_NETWORK=false
SUBCMD="${1:-sync}"
SUBCMD_ARG="${2:-}"

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

log() {
  local msg="[$(date '+%H:%M:%S')] $*"
  echo "$msg" >> "$LOG_FILE"
}

log_and_print() {
  local msg="$*"
  echo "$msg"
  log "$msg"
}

# Run command with timeout and logging
run_with_timeout() {
  local label="$1"
  shift
  log "START: $label — cmd: $*"
  local start_time=$(date +%s)
  local output
  if output=$(timeout "$STEP_TIMEOUT" bash -c "$*" 2>&1); then
    local elapsed=$(( $(date +%s) - start_time ))
    log "OK: $label (${elapsed}s)"
    echo "$output"
    return 0
  else
    local exit_code=$?
    local elapsed=$(( $(date +%s) - start_time ))
    if [ $exit_code -eq 124 ]; then
      log "TIMEOUT: $label after ${STEP_TIMEOUT}s"
      log_and_print "    [TIMEOUT] $label (>${STEP_TIMEOUT}s) — see $LOG_FILE"
    else
      log "FAIL: $label (exit=$exit_code, ${elapsed}s)"
      log "  output: $output"
      log_and_print "    [FAIL] $label (exit=$exit_code) — see $LOG_FILE"
    fi
    return $exit_code
  fi
}

make_link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then rm "$dst"
  elif [ -e "$dst" ]; then mv "$dst" "${dst}.bak.$(date +%s)"; echo "    [BACKUP] $dst"
  fi
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  log_and_print "    [LINK] $(basename "$dst") → $src"
}

cmd_sync() {
  log "=== cc-bootstrap sync started ==="
  log "  Platform: $(uname -s) $(uname -m)"
  log "  Shell: $SHELL"
  log "  PATH: $PATH"
  echo "=== cc-bootstrap sync ==="
  echo "  Log: $LOG_FILE"
  echo ""
  # Dependencies
  for cmd in git node npm python3; do
    command -v $cmd &>/dev/null || { log_and_print "[FAIL] $cmd not found"; ERRORS=$((ERRORS+1)); }
  done
  [ $ERRORS -gt 0 ] && echo "FATAL: missing deps" && exit 1

  # Claude commands
  echo "[1] Claude commands"
  mkdir -p "$CONFIG_DIR/commands"
  for f in "$SCRIPT_DIR/runtimes/claude/commands/"*.md; do
    [ -f "$f" ] && make_link "$f" "$CONFIG_DIR/commands/$(basename "$f")"
  done

  # Claude hooks
  if ls "$SCRIPT_DIR/runtimes/claude/hooks/"* &>/dev/null 2>&1; then
    echo "[2] Claude hooks"
    mkdir -p "$CONFIG_DIR/hooks"
    for f in "$SCRIPT_DIR/runtimes/claude/hooks/"*; do
      [ -f "$f" ] && make_link "$f" "$CONFIG_DIR/hooks/$(basename "$f")"
    done
  fi

  # Codex
  echo "[3] Codex"
  mkdir -p "$CODEX_DIR"
  [ -f "$SCRIPT_DIR/runtimes/codex/instructions.md" ] && \
    make_link "$SCRIPT_DIR/runtimes/codex/instructions.md" "$CODEX_DIR/instructions.md"

  # Gemini
  echo "[4] Gemini"
  mkdir -p "$GEMINI_DIR"
  [ -f "$SCRIPT_DIR/runtimes/gemini/GEMINI.md" ] && \
    make_link "$SCRIPT_DIR/runtimes/gemini/GEMINI.md" "$GEMINI_DIR/GEMINI.md"

  # Shared skills (from registry.yaml)
  echo "[5] Shared skills"
  if [ -f "$SCRIPT_DIR/skills/registry.yaml" ] && command -v python3 &>/dev/null; then
    python3 << PYEOF
import sys, os
try:
    import yaml
except ImportError:
    print("    [WARN] PyYAML missing. pip install pyyaml")
    sys.exit(0)
with open("$SCRIPT_DIR/skills/registry.yaml") as f:
    reg = yaml.safe_load(f)
dirs = {"claude": "$CONFIG_DIR/skills", "codex": "$CODEX_DIR/skills", "gemini": "$GEMINI_DIR/skills"}
for name, info in reg.items():
    for rt in info.get("runtimes", []):
        if rt not in dirs: continue
        src = os.path.join("$SCRIPT_DIR", info["path"], rt)
        if not os.path.exists(src): src = os.path.join("$SCRIPT_DIR", info["path"])
        dst = os.path.join(dirs[rt], name)
        os.makedirs(dirs[rt], exist_ok=True)
        if os.path.islink(dst): os.remove(dst)
        elif os.path.exists(dst): os.rename(dst, dst+".bak")
        os.symlink(src, dst)
        print(f"    [LINK] {rt}/{name} → {src}")
PYEOF
  fi

  # Statusline
  echo "[6] Statusline"
  if [ -f "$SCRIPT_DIR/ui/statusline/my-statusline.mjs" ]; then
    mkdir -p "$CONFIG_DIR/hud"
    make_link "$SCRIPT_DIR/ui/statusline/my-statusline.mjs" "$CONFIG_DIR/hud/my-statusline.mjs"
  fi

  # Network-dependent steps (skip with --skip-network)
  if $SKIP_NETWORK; then
    log_and_print "[7-10] Skipped (--skip-network)"
    log "=== sync complete (network steps skipped) ==="
    echo ""
    echo "=== sync complete (network steps skipped). Restart Claude Code to apply. ==="
    echo "  Full log: $LOG_FILE"
    return
  fi

  # External tools
  log_and_print "[7] External tools"
  # codex-gemini-mcp
  if command -v codex-mcp &>/dev/null; then
    log_and_print "    [OK] codex-mcp installed"
  else
    log_and_print "    Installing codex-gemini-mcp fork..."
    run_with_timeout "codex-gemini-mcp install" \
      "curl -sL https://raw.githubusercontent.com/Byun-jinyoung/codex-gemini-mcp/main/install.sh | bash" \
      | tail -3 || true
  fi
  # gemini-swarm
  if command -v gemini &>/dev/null; then
    if run_with_timeout "gemini list-extensions" "gemini --list-extensions" 2>/dev/null | grep -q "gemini-swarm"; then
      log_and_print "    [OK] gemini-swarm installed"
    else
      run_with_timeout "gemini-swarm install" \
        "gemini extensions install https://github.com/tmdgusya/gemini-swarm --consent" \
        | tail -1 || true
    fi
  fi
  # OMC patches
  if [ -f "$SCRIPT_DIR/patches/omc/omc-render-model-first.sh" ]; then
    run_with_timeout "OMC patches" "bash '$SCRIPT_DIR/patches/omc/omc-render-model-first.sh'" \
      | sed 's/^/    /' || true
  fi

  # [8] Claude Code plugins
  log_and_print "[8] Plugins"
  if command -v claude &>/dev/null; then
    log_and_print "    Fetching plugin list..."
    local plugin_list
    plugin_list=$(timeout 30 claude plugin list < /dev/null 2>&1) || {
      log_and_print "    [WARN] claude plugin list failed (timeout or error), skipping"
      plugin_list=""
    }
    [ -n "$plugin_list" ] && log_and_print "    Plugin list retrieved."

    install_plugin() {
      local name="$1" match="$2" marketplace="$3" pkg="$4"
      log_and_print "    [$name] checking..."
      if [ -n "$plugin_list" ] && echo "$plugin_list" | grep -q "$match"; then
        log_and_print "    [$name] OK — already installed"
      elif [ -z "$plugin_list" ]; then
        log_and_print "    [$name] SKIP — plugin list unavailable"
      else
        if [ -n "$marketplace" ]; then
          log_and_print "    [$name] marketplace add..."
          run_with_timeout "$name marketplace add" "claude plugin marketplace add $marketplace < /dev/null" | tail -1 || true
        fi
        log_and_print "    [$name] installing..."
        run_with_timeout "$name install" "claude plugin install $pkg < /dev/null" | tail -1 || true
      fi
    }

    install_plugin "octo" "octo@nyldn" "https://github.com/nyldn/claude-octopus.git" "octo@nyldn-plugins"
    install_plugin "claude-mem" "claude-mem@thedotmack" "thedotmack/claude-mem" "claude-mem@thedotmack"
    install_plugin "ouroboros" "ouroboros@ouroboros" "Q00/ouroboros" "ouroboros@ouroboros"
    install_plugin "document-skills" "document-skills@anthropic" "anthropics/skills" "document-skills@anthropic-agent-skills"
    install_plugin "oh-my-claudecode" "oh-my-claudecode" "https://github.com/Yeachan-Heo/oh-my-claudecode" "oh-my-claudecode"
    install_plugin "context-mode" "context-mode@context-mode" "mksglu/context-mode" "context-mode@context-mode"
  else
    log_and_print "    [SKIP] Claude Code not found"
  fi

  # [9] MCP servers
  log_and_print "[9] MCP servers"
  if command -v claude &>/dev/null; then
    log_and_print "    Fetching MCP list..."
    local mcp_list
    mcp_list=$(timeout 30 claude mcp list < /dev/null 2>&1) || {
      log_and_print "    [WARN] claude mcp list failed (timeout or error), skipping"
      mcp_list=""
    }
    [ -n "$mcp_list" ] && log_and_print "    MCP list retrieved."

    add_mcp() {
      local name="$1" cmd="$2" binary="$3"
      log_and_print "    [$name] checking..."
      if echo "$mcp_list" | grep -q "$name"; then
        log_and_print "    [$name] OK — already registered"
      elif [ -n "$binary" ] && ! command -v "$binary" &>/dev/null; then
        log_and_print "    [$name] SKIP — $binary binary not found"
      else
        log_and_print "    [$name] registering..."
        local result
        if result=$(run_with_timeout "$name mcp add" "$cmd < /dev/null" 2>&1); then
          log_and_print "    [$name] registered successfully"
        else
          log_and_print "    [$name] registration failed — see $LOG_FILE"
        fi
      fi
    }

    add_mcp "codex-mcp" "claude mcp add codex-mcp -- codex-mcp" "codex-mcp"
    add_mcp "gemini-mcp" "claude mcp add gemini-mcp -e MCP_GEMINI_DEFAULT_MODEL=gemini-3.1-pro-preview -- gemini-mcp" "gemini-mcp"
    add_mcp "serena" "claude mcp add serena -- uvx --from 'git+https://github.com/oraios/serena' serena start-mcp-server" ""
    add_mcp "supermemory" "claude mcp add --transport http supermemory https://mcp.supermemory.ai/mcp" ""
  fi

  # [10] Frameworks (GSD + RTK)
  log_and_print "[10] Frameworks"
  # GSD
  if ls "$CONFIG_DIR/commands/gsd"* &>/dev/null 2>&1; then
    log_and_print "    [OK] GSD already installed"
  else
    log_and_print "    Installing GSD (npx get-shit-done-cc)..."
    # GSD installs by running bin/install.js which copies .md files to ~/.claude/commands/
    # npx is the official method; --yes prevents interactive prompt; stdin from /dev/null prevents hang
    run_with_timeout "GSD install" "npx --yes get-shit-done-cc@latest < /dev/null" | tail -3 || {
      # Fallback: download tarball and run install.js directly
      log_and_print "    [WARN] npx failed, trying manual install..."
      run_with_timeout "GSD manual install" \
        "cd /tmp && npm pack get-shit-done-cc@latest < /dev/null && tar xzf get-shit-done-cc-*.tgz && node package/bin/install.js && rm -rf package get-shit-done-cc-*.tgz" \
        | tail -3 || true
    }
  fi
  # RTK (cross-platform: macOS + Linux)
  if command -v rtk &>/dev/null; then
    log_and_print "    [OK] RTK $(rtk --version 2>/dev/null)"
  else
    log_and_print "    Installing RTK..."
    run_with_timeout "RTK install" \
      "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh" \
      | tail -3 || true
    export PATH="$HOME/.local/bin:$PATH"
    if command -v rtk &>/dev/null; then
      run_with_timeout "RTK init" "rtk init -g < /dev/null" | tail -1 || true
      log_and_print "    [OK] RTK installed: $(rtk --version 2>/dev/null)"
    else
      log_and_print "    [WARN] RTK install failed. See https://github.com/rtk-ai/rtk"
    fi
  fi

  log "=== sync complete ==="
  echo ""
  echo "=== sync complete. Restart Claude Code to apply. ==="
  echo "  Full log: $LOG_FILE"
}

cmd_doctor() {
  echo "=== cc-bootstrap doctor ==="

  echo "[ CLI tools ]"
  for cmd in git node npm python3 uv claude codex gemini rtk playwright; do
    if command -v $cmd &>/dev/null; then echo "  [OK] $cmd"
    else echo "  [MISS] $cmd"; WARNINGS=$((WARNINGS+1)); fi
  done

  echo ""
  echo "[ Symlinks ]"
  for f in "$CONFIG_DIR/commands/analyze-paper.md" "$CONFIG_DIR/commands/update-feeds.md" \
    "$CODEX_DIR/instructions.md" "$GEMINI_DIR/GEMINI.md"; do
    if [ -L "$f" ] || [ -f "$f" ]; then echo "  [OK] $(basename "$f")"
    else echo "  [MISS] $f"; WARNINGS=$((WARNINGS+1)); fi
  done

  echo ""
  echo "[ Plugins ]"
  if command -v claude &>/dev/null; then
    for p in "octo@nyldn" "claude-mem@thedotmack" "ouroboros@ouroboros" "document-skills@anthropic" "oh-my-claudecode" "context-mode@context-mode"; do
      if claude plugin list 2>/dev/null | grep -q "$p"; then echo "  [OK] $p"
      else echo "  [MISS] $p"; WARNINGS=$((WARNINGS+1)); fi
    done
  fi

  echo ""
  echo "[ MCP servers ]"
  if command -v claude &>/dev/null; then
    for m in codex-mcp gemini-mcp serena supermemory slack-server; do
      if claude mcp list 2>/dev/null | grep -q "$m.*Connected"; then echo "  [OK] $m"
      else echo "  [MISS] $m"; WARNINGS=$((WARNINGS+1)); fi
    done
  fi

  echo ""
  echo "[ Frameworks ]"
  if ls "$CONFIG_DIR/commands/gsd"* &>/dev/null 2>&1; then echo "  [OK] GSD"
  else echo "  [MISS] GSD"; WARNINGS=$((WARNINGS+1)); fi
  if command -v rtk &>/dev/null; then echo "  [OK] RTK"
  else echo "  [MISS] RTK"; WARNINGS=$((WARNINGS+1)); fi

  echo ""
  [ $WARNINGS -gt 0 ] && echo "  $WARNINGS item(s) missing." || echo "  All checks passed."
}

cmd_validate() {
  echo "=== cc-bootstrap validate ==="
  for skill_dir in "$SCRIPT_DIR/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "$skill_dir")"
    found=false
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
  cp "$SCRIPT_DIR/runtimes/gemini/GEMINI.md" "$GEMINI_DIR/" 2>/dev/null || true
  cp "$SCRIPT_DIR/ui/statusline/my-statusline.mjs" "$CONFIG_DIR/hud/" 2>/dev/null || true
  for rt in codex gemini; do
    for sd in "$SCRIPT_DIR/skills/"*/; do
      [ -d "$sd/$rt" ] && mkdir -p "$HOME/.$rt/skills/$(basename "$sd")" && \
        cp "$sd/$rt/"* "$HOME/.$rt/skills/$(basename "$sd")/" 2>/dev/null
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
