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

log() {
  local msg="[$(date '+%H:%M:%S')] $*"
  echo "$msg" >> "$LOG_FILE"
}

log_and_print() {
  local msg="$*"
  echo "$msg"
  log "$msg"
}

# Run command with timeout (if available) and logging
run_with_timeout() {
  local label="$1"
  shift
  log "START: $label — cmd: $*"
  local start_time=$(date +%s)
  local output
  
  # Check for timeout or gtimeout
  local timeout_cmd=""
  if command -v timeout &>/dev/null; then
    timeout_cmd="timeout $STEP_TIMEOUT"
  elif command -v gtimeout &>/dev/null; then
    timeout_cmd="gtimeout $STEP_TIMEOUT"
  fi

  if output=$($timeout_cmd bash -c "$*" 2>&1); then
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

# Verify codex-mcp / gemini-mcp install integrity.
# Past failure modes this guards against:
#   1. JS entry files missing +x bit  → "Permission denied" on spawn  → auto-fixed via chmod
#   2. Original donghae0414 upstream installed instead of Byun-jinyoung fork
#      → missing session_id resume + gemini -y flag  → detected via dist feature grep
#   3. Dangling /usr/bin symlink (target deleted/renamed)  → readlink -f resolves nothing
# Returns 0 on healthy install, 1 if reinstall needed.
# Side effects: chmod +x on entry files (auto-repair, idempotent).
verify_codex_gemini_mcp() {
  local bin entry dist_dir
  for bin in codex-mcp gemini-mcp; do
    command -v "$bin" &>/dev/null || return 1
    entry="$(readlink -f "$(command -v "$bin")")"
    [ -f "$entry" ] || return 1
    [ -x "$entry" ] || chmod +x "$entry" 2>/dev/null || return 1
  done
  # entry path: <dist>/mcp/{codex,gemini}-stdio-entry.js
  entry="$(readlink -f "$(command -v codex-mcp)")"
  dist_dir="$(dirname "$(dirname "$entry")")"
  # Fork-only features (Byun-jinyoung): session_id resume, gemini -y
  grep -q 'session_id' "$dist_dir/providers/codex.js" 2>/dev/null || return 1
  grep -q '"-y"' "$dist_dir/providers/gemini.js" 2>/dev/null || return 1
  return 0
}

# Smoke test: spawn MCP binary, confirm "started on stdio" handshake.
# Catches runtime errors that pass static integrity check (e.g. missing dep, bad shebang).
mcp_spawn_check() {
  local bin="$1"
  command -v "$bin" &>/dev/null || return 1
  timeout 3 "$bin" </dev/null 2>&1 | head -1 | grep -q 'started on stdio'
}

append_section_if_missing() {
  local file="$1" marker="$2" section="$3"
  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ] && grep -qF "$marker" "$file"; then
    echo "    [OK] $(basename "$file") already has graphify"
  elif [ -f "$file" ]; then
    printf '\n%s\n' "$section" >> "$file"
    echo "    [OK] Added graphify section to $file"
  else
    printf '%s\n' "$section" > "$file"
    echo "    [OK] Created $file with graphify section"
  fi
}

ensure_line_in_file() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ] && grep -qxF "$line" "$file"; then
    echo "    [OK] $line already in $file"
  else
    printf '%s\n' "$line" >> "$file"
    echo "    [OK] Added $line to $file"
  fi
}

ensure_codex_multi_agent() {
  if ! command -v python3 &>/dev/null; then
    log_and_print "    [SKIP] python3 not available"
    return
  fi
  python3 - "$CODEX_DIR" << 'PYEOF' | sed 's/^/    /'
import re, sys
from pathlib import Path

codex_dir = Path(sys.argv[1])
cfg = codex_dir / "config.toml"
cfg.parent.mkdir(parents=True, exist_ok=True)
content = cfg.read_text() if cfg.exists() else ""

features_re = re.compile(r"(?ms)^\[features\]\n(?P<body>.*?)(?=^\[|\Z)")
match = features_re.search(content)
if match:
    body = match.group("body")
    if re.search(r"(?m)^multi_agent\s*=\s*true\s*$", body):
        print(f"[OK] Codex: multi_agent already enabled in {cfg.name}")
    elif re.search(r"(?m)^multi_agent\s*=", body):
        start, end = match.span("body")
        body = re.sub(r"(?m)^multi_agent\s*=.*$", "multi_agent = true", body)
        content = content[:start] + body + content[end:]
        cfg.write_text(content)
        print(f"[OK] Codex: set multi_agent = true in {cfg.name}")
    else:
        insert_at = match.end("body")
        content = content[:insert_at] + "multi_agent = true\n" + content[insert_at:]
        cfg.write_text(content)
        print(f"[OK] Codex: added multi_agent = true to {cfg.name}")
else:
    prefix = "\n" if content and not content.endswith("\n") else ""
    content += f"{prefix}\n[features]\nmulti_agent = true\n"
    cfg.write_text(content)
    print(f"[OK] Codex: created [features] multi_agent in {cfg.name}")
PYEOF
}

ensure_codex_context_mode() {
  if ! command -v node &>/dev/null; then
    log_and_print "    [SKIP] node not available"
    return
  fi
  node << 'JSEOF' | sed 's/^/    /'
const fs = require("fs");
const os = require("os");
const path = require("path");

const codexDir = path.join(os.homedir(), ".codex");
fs.mkdirSync(codexDir, { recursive: true });

const cfg = path.join(codexDir, "config.toml");
let content = fs.existsSync(cfg) ? fs.readFileSync(cfg, "utf8") : "";
if (/^\[mcp_servers\.context-mode\]$/m.test(content)) {
  console.log("[OK] Codex: context-mode MCP already in config.toml");
} else {
  if (content && !content.endsWith("\n")) content += "\n";
  content += '\n[mcp_servers.context-mode]\ncommand = "context-mode"\n';
  fs.writeFileSync(cfg, content);
  console.log("[OK] Codex: added context-mode MCP to config.toml");
}

const hooksPath = path.join(codexDir, "hooks.json");
let data = {};
if (fs.existsSync(hooksPath)) {
  try {
    data = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  } catch {
    const backup = `${hooksPath}.bak.${Date.now()}`;
    fs.copyFileSync(hooksPath, backup);
    console.log(`[WARN] Codex: hooks.json invalid; backed up to ${backup}`);
  }
}
data.hooks = data.hooks || {};
const wanted = {
  PreToolUse: {
    matcher: "local_shell|shell|shell_command|exec_command|container.exec|Bash|Shell|grep_files|mcp__plugin_context-mode_context-mode__ctx_execute|mcp__plugin_context-mode_context-mode__ctx_execute_file|mcp__plugin_context-mode_context-mode__ctx_batch_execute",
    command: "context-mode hook codex pretooluse",
  },
  PostToolUse: { command: "context-mode hook codex posttooluse" },
  SessionStart: { command: "context-mode hook codex sessionstart" },
  UserPromptSubmit: { command: "context-mode hook codex userpromptsubmit" },
  Stop: { command: "context-mode hook codex stop" },
};
for (const [event, spec] of Object.entries(wanted)) {
  const existing = Array.isArray(data.hooks[event]) ? data.hooks[event] : [];
  const filtered = existing.filter((entry) => !JSON.stringify(entry).includes(spec.command));
  const entry = { hooks: [{ type: "command", command: spec.command }] };
  if (spec.matcher) entry.matcher = spec.matcher;
  filtered.push(entry);
  data.hooks[event] = filtered;
}
fs.writeFileSync(hooksPath, JSON.stringify(data, null, 2) + "\n");
console.log("[OK] Codex: context-mode hooks installed in hooks.json");

const npmRoot = (() => {
  try {
    return require("child_process").execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
})();
const routeSrc = npmRoot ? path.join(npmRoot, "context-mode", "configs", "codex", "AGENTS.md") : "";
const routeDst = path.join(codexDir, "AGENTS.md");
if (!routeSrc || !fs.existsSync(routeSrc)) {
  console.log("[WARN] Codex: context-mode routing AGENTS.md not found; skipping");
} else if (!fs.existsSync(routeDst)) {
  fs.copyFileSync(routeSrc, routeDst);
  console.log("[OK] Codex: copied context-mode routing instructions to ~/.codex/AGENTS.md");
} else if (fs.readFileSync(routeDst, "utf8").includes("context-mode")) {
  console.log("[OK] Codex: ~/.codex/AGENTS.md already has context-mode instructions");
} else {
  console.log("[WARN] Codex: ~/.codex/AGENTS.md exists without context-mode; left unchanged");
}
JSEOF
}

ensure_codex_rtk_inline() {
  local agents_file="$CODEX_DIR/AGENTS.md"
  local marker="## RTK - Rust Token Killer (Codex enforced)"
  mkdir -p "$CODEX_DIR"
  if [ -f "$agents_file" ] && grep -qF "$marker" "$agents_file"; then
    log_and_print "    [OK] Codex: inline RTK instructions already present"
    return
  fi
  cat >> "$agents_file" << 'MDEOF'

## RTK - Rust Token Killer (Codex enforced)

When running shell commands, prefix token-heavy or inspect-style commands with `rtk`.
This applies even if `@RTK.md` include expansion is unavailable.

Examples:
- `ls -la path` -> `rtk ls -la path`
- `git status` -> `rtk git status`
- `grep pattern file` -> `rtk grep pattern file`
- `npm run build` -> `rtk npm run build`

Use raw shell only when the command must not be filtered, when debugging RTK itself,
or when the command is a shell-only control operation such as `cd`.
MDEOF
  log_and_print "    [OK] Codex: added inline RTK instructions to AGENTS.md"
}

write_graphify_project_config() {
  local project_path="$1"
  local graphify_section='## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- For cross-module "how does X relate to Y" questions, prefer `graphify query "<question>"`, `graphify path "<A>" "<B>"`, or `graphify explain "<concept>"` over grep — these traverse the graph'\''s EXTRACTED + INFERRED edges instead of scanning files
- After modifying code files in this session, run `graphify update .` to keep the graph current (AST-only, no API cost)'

  echo "[6] Graphify project integration"
  append_section_if_missing "$project_path/AGENTS.md" "## graphify" "$graphify_section"
  append_section_if_missing "$project_path/CLAUDE.md" "## graphify" "$graphify_section"

  python3 - "$project_path" << 'PYEOF' | sed 's/^/    /'
import json, sys
from pathlib import Path

project = Path(sys.argv[1])

codex_hook = {
    "matcher": "Bash",
    "hooks": [{
        "type": "command",
        "command": "[ -f graphify-out/graph.json ] && echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"graphify: Knowledge graph exists. Read graphify-out/GRAPH_REPORT.md for god nodes and community structure before searching raw files.\"}}' || true",
    }],
}
claude_hook = {
    "matcher": "Bash",
    "hooks": [{
        "type": "command",
        "command": "CMD=$(python3 -c \"import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',d).get('command',''))\" 2>/dev/null || true); case \"$CMD\" in *grep*|*rg\\ *|*ripgrep*|*find\\ *|*fd\\ *|*ack\\ *|*ag\\ *)   [ -f graphify-out/graph.json ] &&   echo '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"graphify: Knowledge graph exists. Read graphify-out/GRAPH_REPORT.md for god nodes and community structure before searching raw files.\"}}'   || true ;; esac",
    }],
}

def load_json(path):
    if path.exists():
        try:
            return json.loads(path.read_text())
        except json.JSONDecodeError:
            return {}
    return {}

def install_hook(path, hook):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = load_json(path)
    pre_tool = data.setdefault("hooks", {}).setdefault("PreToolUse", [])
    data["hooks"]["PreToolUse"] = [h for h in pre_tool if "graphify" not in str(h)]
    data["hooks"]["PreToolUse"].append(hook)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    print(f"[OK] {path.relative_to(project)} graphify hook installed")

install_hook(project / ".codex" / "hooks.json", codex_hook)
install_hook(project / ".claude" / "settings.json", claude_hook)
PYEOF

  echo "[7] Graphify ignore rules"
  for line in ".git/" ".obsidian/" ".claude/" ".codex/" ".serena/" ".code-review-graph/" "graphify-out/" "node_modules/" ".DS_Store" "*.tmp" "*.log"; do
    ensure_line_in_file "$project_path/.graphifyignore" "$line"
  done
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
  echo "[3b] Codex feature flags"
  ensure_codex_multi_agent

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
    yaml = None

registry_path = "$SCRIPT_DIR/skills/registry.yaml"
if yaml:
    with open(registry_path) as f:
        reg = yaml.safe_load(f)
else:
    print("    [WARN] PyYAML missing. Using minimal registry parser.")
    reg = {}
    current = None
    with open(registry_path) as f:
        for raw in f:
            line = raw.split("#", 1)[0].rstrip()
            if not line:
                continue
            if not line.startswith(" ") and line.endswith(":"):
                current = line[:-1]
                reg[current] = {}
            elif current and line.strip().startswith("path:"):
                reg[current]["path"] = line.split(":", 1)[1].strip()
            elif current and line.strip().startswith("runtimes:"):
                value = line.split(":", 1)[1].strip()
                reg[current]["runtimes"] = [x.strip() for x in value.strip("[]").split(",") if x.strip()]
dirs = {"claude": "$CONFIG_DIR/skills", "codex": "$CODEX_DIR/skills", "agents": "$AGENTS_DIR/skills", "gemini": "$GEMINI_DIR/skills"}
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
  # context-mode (Codex MCP + hooks)
  if command -v context-mode &>/dev/null; then
    log_and_print "    [OK] context-mode installed"
  else
    log_and_print "    Installing context-mode (npm global)..."
    run_with_timeout "context-mode install" "npm install -g context-mode < /dev/null" \
      | tail -3 || true
  fi
  # codex-gemini-mcp (Byun-jinyoung fork — required for session_id resume + gemini -y)
  # Integrity check covers: binary present, exec bit set, fork features in dist.
  # Auto-repairs missing exec bit; reinstalls if fork features absent.
  if verify_codex_gemini_mcp; then
    log_and_print "    [OK] codex-mcp + gemini-mcp (fork integrity verified)"
  else
    log_and_print "    Installing/repairing codex-gemini-mcp fork..."
    run_with_timeout "codex-gemini-mcp install" \
      "curl -sL https://raw.githubusercontent.com/Byun-jinyoung/codex-gemini-mcp/main/install.sh | bash" \
      | tail -3 || true
    if verify_codex_gemini_mcp; then
      log_and_print "    [OK] codex-gemini-mcp fork installed and verified"
    else
      log_and_print "    [WARN] codex-gemini-mcp install ran but integrity still failing — see $LOG_FILE"
    fi
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

  # [9b] Codex / Gemini MCP registration (for triangle-review + codebase-scan)
  # serena와 code-review-graph는 ~/.codex/config.toml과 ~/.gemini/settings.json에
  # 별도 등록되어야 함 (claude mcp add는 Claude Code에만 등록됨)
  log_and_print "[9b] Codex/Gemini MCP entries"
  if command -v python3 &>/dev/null; then
    python3 - "$CODEX_DIR" "$GEMINI_DIR" << 'PYEOF' | sed 's/^/    /'
import json, os, sys
from pathlib import Path

codex_dir, gemini_dir = sys.argv[1], sys.argv[2]

# External MCPs needed by triangle-review + codebase-scan
WANTED = {
    "serena": {
        "command": "uvx",
        "args": ["--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server"],
    },
    "code-review-graph": {
        "command": "code-review-graph",
        "args": ["serve"],
    },
    "context-mode": {
        "command": "context-mode",
    },
}

# --- Codex (TOML, ~/.codex/config.toml) ---
# (Note: ensure_codex_context_mode handles context-mode in Codex specifically)
codex_cfg = Path(codex_dir) / "config.toml"
codex_cfg.parent.mkdir(parents=True, exist_ok=True)
if not codex_cfg.exists():
    codex_cfg.write_text("")
    print(f"[CREATE] {codex_cfg}")
content = codex_cfg.read_text()

def has_codex_section(name):
    return f"[mcp_servers.{name}]" in content

added_codex = []
for name, spec in WANTED.items():
    if name == "context-mode": continue # Handled by ensure_codex_context_mode
    if has_codex_section(name):
        continue
    block = [f"\n[mcp_servers.{name}]",
             f'command = "{spec["command"]}"',
             "args = [" + ", ".join(f'"{a}"' for a in spec["args"]) + "]",
             ""]
    content += "\n".join(block)
    added_codex.append(name)

if added_codex:
    codex_cfg.write_text(content)
    print(f"[OK] Codex: added {', '.join(added_codex)} to {codex_cfg.name}")
else:
    print(f"[OK] Codex: serena + code-review-graph already in {codex_cfg.name}")

# --- Gemini (JSON, ~/.gemini/settings.json) ---
gemini_cfg = Path(gemini_dir) / "settings.json"
gemini_cfg.parent.mkdir(parents=True, exist_ok=True)
if gemini_cfg.exists():
    try:
        data = json.loads(gemini_cfg.read_text())
    except json.JSONDecodeError:
        print(f"[WARN] {gemini_cfg} unparseable — skipping (back up + edit manually)")
        sys.exit(0)
else:
    data = {}

# Dynamic path resolution for context-mode
import subprocess, os
def get_cm_paths():
    try:
        npm_root = subprocess.check_output(["npm", "root", "-g"], text=True).strip()
        bundle_path = os.path.join(npm_root, "context-mode", "cli.bundle.mjs")
        bin_path = subprocess.check_output(["which", "context-mode"], text=True).strip()
        if os.path.exists(bundle_path):
            return bundle_path, bin_path
    except:
        pass
    return None, "context-mode"

cm_path, cm_bin = get_cm_paths()

mcp_servers = data.setdefault("mcpServers", {})
added_gemini = []
for name, spec in WANTED.items():
    # Force update context-mode to ensure absolute path integrity
    if name == "context-mode" and cm_path:
        new_spec = {"command": "node", "args": [cm_path]}
        if mcp_servers.get(name) != new_spec:
            mcp_servers[name] = new_spec
            added_gemini.append(name)
        continue
        
    if name in mcp_servers:
        continue
    mcp_servers[name] = spec
    added_gemini.append(name)

# Gemini Hooks for context-mode
hooks = data.setdefault("hooks", {})
gemini_hooks = {
    "BeforeTool": {
        "matcher": "run_shell_command|read_file|read_many_files|grep_search|search_file_content|web_fetch|activate_skill|mcp__plugin_context-mode",
        "command": f"{cm_bin} hook gemini-cli beforetool"
    },
    "AfterTool": { "command": f"{cm_bin} hook gemini-cli aftertool" },
    "PreCompress": { "command": f"{cm_bin} hook gemini-cli precompress" },
    "SessionStart": { "command": f"{cm_bin} hook gemini-cli sessionstart" }
}

for event, spec in gemini_hooks.items():
    existing = hooks.setdefault(event, [])
    # Integrity check: Ensure any existing context-mode hook uses the absolute binary path
    updated_any = False
    for h_wrapper in existing:
        for h in h_wrapper.get("hooks", []):
            if "context-mode hook gemini-cli" in h.get("command", ""):
                cmd = h["command"]
                if not cmd.startswith("/") and cm_bin.startswith("/"):
                    h["command"] = cmd.replace("context-mode", cm_bin)
                    updated_any = True
    
    if updated_any:
        added_gemini.append(f"hook-fix:{event}")

    if not any(spec["command"] in str(h) for h in existing):
        h_obj = {"hooks": [{"type": "command", "command": spec["command"]}]}
        if "matcher" in spec: h_obj["matcher"] = spec["matcher"]
        existing.append(h_obj)
        added_gemini.append(f"hook:{event}")

if added_gemini:
    gemini_cfg.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    print(f"[OK] Gemini: updated {', '.join(added_gemini)}")
else:
    print(f"[OK] Gemini: context-mode already configured")
PYEOF
  else
    log_and_print "    [SKIP] python3 not available"
  fi
  if command -v context-mode &>/dev/null; then
    ensure_codex_context_mode
  else
    log_and_print "    [WARN] context-mode missing. Install Node package first: npm install -g context-mode"
  fi

  # [10] Frameworks
  log_and_print "[10] Frameworks"
  export PATH="$HOME/.local/bin:$PATH"

  # GSD
  # Detect via either old commands/ path or current skills/ layout (GSD restructured upstream).
  if ls "$CONFIG_DIR/commands/gsd"* &>/dev/null 2>&1 || ls -d "$CONFIG_DIR/skills/gsd-"* &>/dev/null 2>&1; then
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
  RTK_BIN="$HOME/.local/bin/rtk"
  if [ -x "$RTK_BIN" ]; then
    log_and_print "    [OK] RTK $($RTK_BIN --version 2>/dev/null)"
  else
    log_and_print "    Installing RTK..."
    run_with_timeout "RTK install" \
      "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh" \
      | tail -3 || true
    export PATH="$HOME/.local/bin:$PATH"
    if command -v rtk &>/dev/null; then
      log_and_print "    [OK] RTK installed: $(rtk --version 2>/dev/null)"
    else
      log_and_print "    [WARN] RTK install failed. See https://github.com/rtk-ai/rtk"
    fi
  fi
  # RTK hook integrity (independent of binary install).
  # Two artifacts must exist:
  #   (a) $CONFIG_DIR/hooks/rtk-rewrite.sh — the shell hook script (created by `rtk init -g`,
  #       header: `# rtk-hook-version: 2`, delegates to `rtk rewrite` Rust binary).
  #   (b) settings.json PreToolUse[matcher=Bash] entry whose command is the (a) path.
  # Past mistake (fixed here): previous versions injected `"command": "rtk hook claude"` as the
  # entry, but that subcommand does NOT exist in rtk ≥ 0.30 (only `rtk hook gemini`/`copilot`).
  # It silently failed with exit 127 on every Bash call. The correct command is the (a) path.
  # `rtk init -g --auto-patch` is best-effort but unreliable in 0.31.0 — we always finish the
  # wiring via direct JSON merge, idempotent + legacy-entry-stripping.
  if command -v rtk &>/dev/null; then
    if [ ! -f "$CONFIG_DIR/hooks/rtk-rewrite.sh" ]; then
      log_and_print "    rtk-rewrite.sh missing — running 'rtk init -g'..."
      run_with_timeout "RTK init -g" "rtk init -g --auto-patch < /dev/null" | tail -3 || true
    fi
    if [ -f "$CONFIG_DIR/hooks/rtk-rewrite.sh" ] && command -v python3 &>/dev/null; then
      python3 - "$CONFIG_DIR/settings.json" "$CONFIG_DIR/hooks/rtk-rewrite.sh" << 'PYEOF' | sed 's/^/    /'
import json, sys
from pathlib import Path
p, hook_path = Path(sys.argv[1]), sys.argv[2]
data = {}
if p.exists():
    try:
        data = json.loads(p.read_text())
    except Exception as e:
        print(f"[WARN] settings.json unparseable ({e}) — aborting merge")
        sys.exit(0)
hooks = data.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
# Strip legacy `rtk hook claude` entries (subcommand never existed; injected by older setup.sh).
before = len(pre)
pre[:] = [
    e for e in pre
    if not (
        isinstance(e, dict) and e.get("matcher") == "Bash" and any(
            isinstance(h, dict) and h.get("command") == "rtk hook claude"
            for h in e.get("hooks", [])
        )
    )
]
removed = before - len(pre)
already = any(
    isinstance(e, dict) and e.get("matcher") == "Bash" and any(
        isinstance(h, dict) and h.get("command") == hook_path
        for h in e.get("hooks", [])
    ) for e in pre
)
if not already:
    pre.append({"matcher": "Bash", "hooks": [{"type": "command", "command": hook_path}]})
if (not already) or removed:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2))
msg = "[OK] RTK hook already wired" if already and not removed else f"[OK] RTK hook wired -> {hook_path}"
if removed:
    msg += f" (stripped {removed} legacy 'rtk hook claude' entr{'y' if removed==1 else 'ies'})"
print(msg)
PYEOF
      if grep -q 'rtk-rewrite.sh' "$CONFIG_DIR/settings.json" 2>/dev/null; then
        log_and_print "    [OK] RTK hook installed (token rewrite active)"
      else
        log_and_print "    [WARN] RTK hook still missing — manual patch required (see $LOG_FILE)"
      fi
    else
      log_and_print "    [WARN] rtk-rewrite.sh hook file missing or python3 unavailable — skipping wire"
    fi
  fi
  # RTK for Codex + Gemini (Claude RTK hook wired above)
  if [ -x "$RTK_BIN" ]; then
    run_with_timeout "RTK init Codex" "$RTK_BIN init -g --codex < /dev/null" | tail -1 || true
    run_with_timeout "RTK init Gemini" "$RTK_BIN init -g --gemini --auto-patch < /dev/null" | tail -1 || true
    ensure_codex_rtk_inline
  fi
  # Graphify — package name is graphifyy; CLI command is graphify.
  export PATH="$HOME/.local/bin:$PATH"
  if command -v graphify &>/dev/null; then
    log_and_print "    [OK] Graphify CLI installed ($(command -v graphify))"
  elif command -v uv &>/dev/null; then
    log_and_print "    Installing Graphify (uv tool install graphifyy)..."
    run_with_timeout "Graphify install (uv)" "uv tool install graphifyy < /dev/null" \
      | tail -2 || true
    if command -v graphify &>/dev/null; then
      log_and_print "    [OK] Graphify installed: $(command -v graphify)"
    else
      log_and_print "    [WARN] Graphify install via uv failed — see $LOG_FILE"
    fi
  else
    log_and_print "    [WARN] Graphify missing. Install uv first, then run: uv tool install graphifyy"
  fi
  # code-review-graph (CRG) — required by triangle-review + codebase-scan
  # CRG requires Python >=3.10. Use `uv tool install` for isolated env that works
  # regardless of system Python version. Fall back to pip3 only when uv missing.
  if command -v code-review-graph &>/dev/null; then
    log_and_print "    [OK] CRG $(code-review-graph --version 2>&1 | head -1)"
  elif command -v uv &>/dev/null; then
    log_and_print "    Installing code-review-graph (uv tool)..."
    run_with_timeout "CRG install (uv)" "uv tool install code-review-graph < /dev/null" \
      | tail -2 || true
    if command -v code-review-graph &>/dev/null; then
      log_and_print "    [OK] CRG installed: $(code-review-graph --version 2>&1 | head -1)"
    else
      log_and_print "    [WARN] CRG install via uv failed — see $LOG_FILE"
    fi
  else
    log_and_print "    [WARN] CRG missing. Install uv first, or pip3 install --user code-review-graph (Python>=3.10)"
  fi

  log "=== sync complete ==="
  echo ""
  echo "=== sync complete. Restart Claude Code to apply. ==="
  echo "  Full log: $LOG_FILE"
}

cmd_doctor() {
  echo "=== cc-bootstrap doctor ==="

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
    for p in "octo@nyldn" "claude-mem@thedotmack" "ouroboros@ouroboros" "document-skills@anthropic" "oh-my-claudecode" "context-mode@context-mode"; do
      if claude plugin list 2>/dev/null | grep -q "$p"; then echo "  [OK] $p"
      else echo "  [MISS] $p"; WARNINGS=$((WARNINGS+1)); fi
    done
  fi

  echo ""
  echo "[ MCP servers (Claude) ]"
  if command -v claude &>/dev/null; then
    for m in codex-mcp gemini-mcp serena supermemory; do
      if claude mcp list 2>/dev/null | grep -qE "$m.*(Connected|Needs authentication)"; then echo "  [OK] $m"
      else echo "  [MISS] $m"; WARNINGS=$((WARNINGS+1)); fi
    done
  fi

  echo ""
  echo "[ codex-gemini-mcp integrity ]"
  if verify_codex_gemini_mcp; then
    entry_path="$(readlink -f "$(command -v codex-mcp 2>/dev/null)" 2>/dev/null)"
    echo "  [OK] fork features present (session_id, gemini -y)"
    echo "        resolved: ${entry_path:-?}"
  else
    echo "  [FAIL] codex-gemini-mcp integrity — run 'setup.sh sync' to repair"
    WARNINGS=$((WARNINGS+1))
  fi
  for bin in codex-mcp gemini-mcp; do
    if mcp_spawn_check "$bin"; then
      echo "  [OK] $bin stdio handshake"
    else
      echo "  [FAIL] $bin stdio spawn — check exec bit / runtime deps"
      WARNINGS=$((WARNINGS+1))
    fi
  done

  echo ""
  echo "[ MCP servers (Codex/Gemini for triangle-review) ]"
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
  if [ -f "$GEMINI_DIR/settings.json" ] && command -v python3 &>/dev/null; then
    python3 - "$GEMINI_DIR/settings.json" << 'PYEOF'
import json, sys
try:
    d = json.loads(open(sys.argv[1]).read())
    servers = d.get("mcpServers", {})
    for name in ("serena", "code-review-graph"):
        if name in servers: print(f"  [OK] gemini {name}")
        else: print(f"  [MISS] gemini {name}")
except Exception as e:
    print(f"  [WARN] gemini settings.json unparseable: {e}")
PYEOF
  else
    echo "  [MISS] gemini settings.json"; WARNINGS=$((WARNINGS+1))
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
  for sk in triangle-review codebase-scan graphify; do
    src="$SCRIPT_DIR/skills/$sk"
    dst="$CONFIG_DIR/skills/$sk"
    if [ -L "$dst" ] && [ -e "$dst" ]; then echo "  [OK] $sk symlink"
    elif [ -e "$dst" ]; then echo "  [WARN] $sk exists but not symlinked from cc-bootstrap"
    else echo "  [MISS] $sk"; WARNINGS=$((WARNINGS+1)); fi
  done
  if [ -L "$AGENTS_DIR/skills/graphify" ] && [ -e "$AGENTS_DIR/skills/graphify" ]; then echo "  [OK] codex graphify symlink"
  elif [ -e "$AGENTS_DIR/skills/graphify" ]; then echo "  [WARN] codex graphify exists but not symlinked from cc-bootstrap"
  else echo "  [MISS] codex graphify"; WARNINGS=$((WARNINGS+1)); fi
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
    if grep -q 'rtk-rewrite.sh' "$CONFIG_DIR/settings.json" 2>/dev/null; then
      echo "  [OK] RTK hook active in settings.json"
      if grep -q 'rtk hook claude' "$CONFIG_DIR/settings.json" 2>/dev/null; then
        echo "  [WARN] legacy 'rtk hook claude' entry also present — run 'setup.sh sync' to strip"
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
  cp "$SCRIPT_DIR/runtimes/gemini/GEMINI.md" "$GEMINI_DIR/" 2>/dev/null || true
  cp "$SCRIPT_DIR/ui/statusline/my-statusline.mjs" "$CONFIG_DIR/hud/" 2>/dev/null || true
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
