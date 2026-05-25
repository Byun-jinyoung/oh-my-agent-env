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

# Run a command with a wall-clock timeout if `timeout`/`gtimeout` is available,
# otherwise run without one. macOS has neither by default, so naive
# `timeout 30 ...` calls would exit 127 every time.
maybe_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then timeout "$secs" "$@"
  elif command -v gtimeout &>/dev/null; then gtimeout "$secs" "$@"
  else "$@"
  fi
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

# Decide a user-owned npm global prefix and export it for all subsequent
# `npm install -g` calls (and child processes like the fork install.sh).
#
# Policy goal (multi-user server isolation):
#   This machine may be a shared host where MY tools and credentials must
#   not be visible/executable to OTHER users on the box. Anything written
#   under /usr/local, /opt, or /usr is by default readable+executable by
#   everyone (mode 0755 on macOS Homebrew; system paths on Linux servers).
#   So we keep everything under $HOME with a mode that excludes group+other.
#
# What this protects:
#   - codex-mcp / antigravity-mcp binaries + their node_modules tree
#     (provider configs, hardcoded model defaults, anything the package
#     ships).
#   - @openai/codex CLI binary tree.
#   - Indirectly: any future package that this script installs globally.
#
# Out of scope (NOT protected by this function — handled elsewhere/by user):
#   - Credential dirs: ~/.codex, ~/.gemini, ~/.claude. These are user-owned
#     state not created by this script; doctor() WARNs if they are readable
#     by other users, but never chmods them automatically (that would
#     overstep — those dirs may have user-chosen sharing).
#
# Decision rule for prefix location:
#   - If `npm config get prefix` is already under $HOME (covers nvm, volta,
#     asdf, or a previously-configured ~/.npm-global), respect it.
#   - Otherwise pick $HOME/.npm-global (the npm-documented per-user default).
#
# Side effects:
#   - mkdir -p <prefix>/{bin,lib} (idempotent).
#   - chmod 700 on the prefix root + bin + lib so other users on a shared
#     host cannot list, read, or exec what we install. macOS default umask
#     0022 would leave them 0755 (world-readable+exec) otherwise.
#   - Exports USER_NPM_PREFIX (used by callers to build env strings).
#   - Exports NPM_USER_ENV: a literal "VAR=VAL VAR=VAL" prefix safe to prepend
#     to any `bash -c "..."` payload (run_with_timeout uses bash -c).
#   - Does NOT modify ~/.npmrc — we keep the user's global npm config alone
#     and instead pass the prefix via env per-invocation.
ensure_user_npm_prefix() {
  local cur=""
  if command -v npm &>/dev/null; then
    cur="$(npm config get prefix 2>/dev/null)"
  fi
  case "$cur" in
    "$HOME"/*) USER_NPM_PREFIX="$cur" ;;
    *)         USER_NPM_PREFIX="$HOME/.npm-global" ;;
  esac
  mkdir -p "$USER_NPM_PREFIX/bin" "$USER_NPM_PREFIX/lib" 2>/dev/null || true
  # Lock owner-only so other users on a shared server can't `ls`, read, or
  # exec what's inside. Idempotent. Only applied if we own the dir (skip if
  # somehow another uid created it — let user inspect).
  if [ -w "$USER_NPM_PREFIX" ] && [ "$(stat -c '%u' "$USER_NPM_PREFIX" 2>/dev/null || stat -f '%u' "$USER_NPM_PREFIX" 2>/dev/null)" = "$(id -u)" ]; then
    chmod 700 "$USER_NPM_PREFIX" "$USER_NPM_PREFIX/bin" "$USER_NPM_PREFIX/lib" 2>/dev/null || true
  fi
  # Env string prepended to npm invocations. npm_config_prefix is the official
  # npm env override (docs.npmjs.com/cli/v10/using-npm/config). Quoting the
  # value handles paths with spaces; the assignment must be bash-c safe.
  NPM_USER_ENV="npm_config_prefix='$USER_NPM_PREFIX'"
  export USER_NPM_PREFIX NPM_USER_ENV
  log "  USER_NPM_PREFIX=$USER_NPM_PREFIX (npm reported: ${cur:-<unset>}, mode locked to 0700)"
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

# Verify Byun-jinyoung fork of codex-gemini-mcp is installed (not upstream).
# Fork distinguishing facts (vs donghae0414 upstream):
#   - bin: codex-mcp + antigravity-mcp  (upstream: codex-mcp + gemini-mcp)
#   - dist/providers/antigravity.js exists with antigravity-specific flags
#   - dist/providers/codex.js retains session_id resume support
# Past failure modes guarded against:
#   1. JS entry files missing +x bit → "Permission denied" → auto-fixed via chmod
#   2. Upstream donghae0414 installed in place of fork → detected via feature grep
#   3. Dangling /usr/bin symlink (target deleted/renamed) → readlink -f resolves nothing
#   4. Pre-2026-06-18 fork still ships gemini-mcp bin → forces reinstall by missing antigravity-mcp
# Returns 0 on healthy fork install, 1 if reinstall needed.
# Side effects: chmod +x on entry files (auto-repair, idempotent).
verify_codex_gemini_mcp() {
  local bin entry dist_dir
  for bin in codex-mcp antigravity-mcp; do
    command -v "$bin" &>/dev/null || return 1
    entry="$(readlink -f "$(command -v "$bin")")"
    [ -f "$entry" ] || return 1
    [ -x "$entry" ] || chmod +x "$entry" 2>/dev/null || return 1
  done
  # entry path: <dist>/mcp/{codex,antigravity}-stdio-entry.js
  entry="$(readlink -f "$(command -v codex-mcp)")"
  dist_dir="$(dirname "$(dirname "$entry")")"
  # Fork-only features (Byun-jinyoung): session_id resume + antigravity provider.
  # Feature-grep is more robust than file-existence because upstream could
  # rename files; the actual invocation signature (session_id, --conversation)
  # is what makes the fork behave correctly.
  grep -q 'session_id' "$dist_dir/providers/codex.js" 2>/dev/null || return 1
  grep -q '"--conversation"' "$dist_dir/providers/antigravity.js" 2>/dev/null || return 1
  return 0
}

# Detect & remove upstream donghae0414 install (and stale system-wide symlinks)
# so the fork install can land cleanly. Idempotent: only acts when upstream
# markers are present. Never touches the fork's own install.
# Side effects: npm uninstall -g per detected prefix; warns about root-owned
# system paths (/usr/bin, /usr/lib/node_modules) that require sudo.
cleanup_upstream_codex_gemini_mcp() {
  local removed=0 prefix pkg_dir warn_sys=0
  # 1. npm-prefix-managed installs (no sudo needed for user-prefix; system
  #    prefix may require sudo — npm itself surfaces the error).
  local prefixes=()
  local p
  # USER_NPM_PREFIX first — that's where this script writes. Always scan it
  # even if `npm config get prefix` reports something else.
  for p in "$USER_NPM_PREFIX" "$(npm config get prefix 2>/dev/null)" "/usr/local" "/opt/homebrew" "$HOME/.npm-global"; do
    [ -n "$p" ] || continue
    # de-dup
    local _dup=0 _q
    for _q in "${prefixes[@]}"; do [ "$_q" = "$p" ] && _dup=1 && break; done
    [ "$_dup" = "0" ] && prefixes+=("$p")
  done
  for prefix in "${prefixes[@]}"; do
    pkg_dir="$prefix/lib/node_modules/@donghae0414/codex-gemini-mcp"
    if [ -d "$pkg_dir" ]; then
      # Confirm it's upstream (has providers/gemini.js); never delete the fork
      if [ -f "$pkg_dir/dist/providers/gemini.js" ] && [ ! -f "$pkg_dir/dist/providers/antigravity.js" ]; then
        log_and_print "    [cleanup] uninstalling upstream @donghae0414/codex-gemini-mcp from $prefix"
        run_with_timeout "npm uninstall upstream ($prefix)" \
          "npm uninstall -g --prefix '$prefix' @donghae0414/codex-gemini-mcp" \
          | tail -2
        local uninstall_rc=${PIPESTATUS[0]}
        if [ "$uninstall_rc" -eq 0 ] && [ ! -d "$pkg_dir" ]; then
          removed=1
        else
          log_and_print "    [cleanup] [WARN] upstream uninstall failed at $prefix (rc=$uninstall_rc); fork may be shadowed on PATH"
          if [[ "$prefix" == /usr/* ]] || [[ "$prefix" == /opt/* ]]; then
            log_and_print "      Try: sudo npm uninstall -g --prefix '$prefix' @donghae0414/codex-gemini-mcp"
          fi
        fi
      fi
    fi
  done
  # 2. Root-owned system-wide leftovers (legacy: /usr/lib/node_modules + /usr/bin).
  #    These are NOT under user npm prefix and require sudo to remove.
  if [ -d "/usr/lib/node_modules/@donghae0414/codex-gemini-mcp" ]; then
    warn_sys=1
    log_and_print "    [cleanup] [SUDO NEEDED] /usr/lib/node_modules/@donghae0414/codex-gemini-mcp present"
    log_and_print "      Remove manually: sudo rm -rf /usr/lib/node_modules/@donghae0414"
  fi
  for sym in /usr/bin/codex-mcp /usr/bin/gemini-mcp /usr/bin/antigravity-mcp; do
    if [ -L "$sym" ]; then
      local tgt
      tgt="$(readlink -f "$sym" 2>/dev/null)"
      # Stale (target gone) OR pointing into /usr/lib/node_modules (legacy system install)
      if [ ! -e "$tgt" ] || [[ "$tgt" == /usr/lib/node_modules/* ]]; then
        warn_sys=1
        log_and_print "    [cleanup] [SUDO NEEDED] stale symlink $sym → ${tgt:-<dangling>}"
        log_and_print "      Remove manually: sudo rm $sym"
      fi
    fi
  done
  [ "$warn_sys" = "1" ] && \
    log_and_print "    [cleanup] system-wide leftovers must be removed before fork can win on PATH"
  return 0
}

# Smoke test: spawn MCP binary, confirm "started on stdio" handshake.
# Catches runtime errors that pass static integrity check (e.g. missing dep, bad shebang).
mcp_spawn_check() {
  local bin="$1"
  command -v "$bin" &>/dev/null || return 1
  maybe_timeout 3 "$bin" </dev/null 2>&1 | head -1 | grep -q 'started on stdio'
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
// ~/.codex/AGENTS.md is assembled by assemble_global_rules (Layer A + Layer B);
// context-mode routing lives in runtimes/codex/tools.md.
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

# Assemble each CLI's global instruction file from:
#   Layer A — rules/*.md          (shared, CLI-agnostic coding rules, SRP modules
#                                  concatenated in filename order: 00, 10, ... 70)
#   Layer B — runtimes/<cli>/tools.md  (CLI-specific tool guidance)
# Regenerated on every sync; idempotent. No @-include — concatenated so it
# works regardless of per-CLI include support.
assemble_global_rules() {
  local rules_dir="$SCRIPT_DIR/rules"
  if [ ! -d "$rules_dir" ] || ! ls "$rules_dir"/*.md >/dev/null 2>&1; then
    log_and_print "    [WARN] Layer A missing ($rules_dir/*.md) — skipping global rule assembly"
    return
  fi
  local cli dir tools target
  for cli in claude codex antigravity; do
    tools="$SCRIPT_DIR/runtimes/$cli/tools.md"
    case "$cli" in
      claude)      dir="$CONFIG_DIR"; target="$CONFIG_DIR/CLAUDE.md" ;;
      codex)       dir="$CODEX_DIR";  target="$CODEX_DIR/AGENTS.md" ;;
      antigravity) dir="$GEMINI_DIR"; target="$GEMINI_DIR/GEMINI.md" ;;
    esac
    if [ ! -f "$tools" ]; then
      log_and_print "    [WARN] $cli Layer B missing ($tools) — skipping"
      continue
    fi
    mkdir -p "$dir"
    { cat "$rules_dir"/*.md; printf '\n'; cat "$tools"; } > "$target"
    log_and_print "    [OK] $target (Layer A rules/ + $cli tools)"
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

  # Force every npm global install in this sync into a $HOME-rooted prefix
  # locked to mode 0700, so on a shared/multi-user server MY tools (codex-mcp,
  # @openai/codex, antigravity-mcp, etc.) are not readable or executable by
  # other users on the box. Anything under /usr/local|/opt|/usr would be 0755
  # by default (world-readable+exec). Sets USER_NPM_PREFIX + NPM_USER_ENV.
  ensure_user_npm_prefix

  # Ensure the user prefix bin is on PATH for this sync run, so later checks
  # like `command -v context-mode` succeed even on shells that haven't added
  # it themselves. Users still need to add it to their shell rc — see
  # post-sync instructions.
  if [ -d "$USER_NPM_PREFIX/bin" ] && [[ ":$PATH:" != *":$USER_NPM_PREFIX/bin:"* ]]; then
    export PATH="$USER_NPM_PREFIX/bin:$PATH"
    log "  Added user npm prefix bin to PATH: $USER_NPM_PREFIX/bin"
  fi
  # Also keep the currently-configured npm prefix bin reachable (only matters
  # if it differs from USER_NPM_PREFIX, e.g. user has a system prefix but we're
  # redirecting writes to ~/.npm-global). Reading old installs is harmless;
  # we never WRITE to it.
  if command -v npm &>/dev/null; then
    local _cur_npm_bin
    _cur_npm_bin="$(npm config get prefix 2>/dev/null)/bin"
    if [ -n "$_cur_npm_bin" ] && [ "$_cur_npm_bin" != "$USER_NPM_PREFIX/bin" ] \
       && [ -d "$_cur_npm_bin" ] && [[ ":$PATH:" != *":$_cur_npm_bin:"* ]]; then
      export PATH="$PATH:$_cur_npm_bin"
      log "  Appended legacy npm prefix bin to PATH (read-only): $_cur_npm_bin"
    fi
  fi

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

  # Global rule files (Layer A + Layer B) — Claude, Codex, Gemini
  echo "[4b] Global rule assembly"
  assemble_global_rules

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
dirs = {"claude": "$CONFIG_DIR/skills", "codex": "$CODEX_DIR/skills", "agents": "$AGENTS_DIR/skills", "antigravity": "$GEMINI_DIR/skills"}
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

# Prune stale cc-bootstrap symlinks no longer in the registry, so that
# dropping a runtime from registry.yaml self-cleans on every machine.
# Only cc-bootstrap-managed symlinks are removed; real dirs / foreign
# links are left untouched.
skills_root = os.path.realpath(os.path.join("$SCRIPT_DIR", "skills"))
desired = {(rt, name) for name, info in reg.items()
           for rt in info.get("runtimes", []) if rt in dirs}
for rt, d in dirs.items():
    if not os.path.isdir(d): continue
    for entry in os.listdir(d):
        p = os.path.join(d, entry)
        if not os.path.islink(p): continue
        if os.path.realpath(p).startswith(skills_root) and (rt, entry) not in desired:
            os.remove(p)
            print(f"    [PRUNE] {rt}/{entry} (stale)")
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
    log_and_print "    Installing context-mode (npm global → $USER_NPM_PREFIX)..."
    run_with_timeout "context-mode install" "$NPM_USER_ENV npm install -g context-mode < /dev/null" \
      | tail -3 || true
    # Verify post-install (install may succeed but bin dir may not be on PATH).
    if command -v context-mode &>/dev/null; then
      log_and_print "    [OK] context-mode installed -> $(command -v context-mode)"
    else
      log_and_print "    [WARN] context-mode still not on PATH after install."
      log_and_print "           Run: echo 'export PATH=\"\$(npm config get prefix)/bin:\$PATH\"' >> ~/.bashrc"
    fi
  fi
  # @openai/codex CLI — REQUIRED by codex-mcp (the MCP spawns `codex` from PATH).
  # Without this, codex-mcp connects but every request fails on first spawn.
  #
  # DETERMINISTIC install policy (avoids "different machine, different path"):
  #   1. SCAN all known bin locations for existing `codex` binaries.
  #   2. If MULTIPLE installs exist → list them, identify PATH winner, WARN
  #      (do not auto-install; let user resolve to one canonical location).
  #   3. If EXACTLY ONE exists → record path, skip install.
  #   4. If NONE → install via `npm install -g @openai/codex`, then re-scan.
  local _codex_cands=()
  local _seg _npm_prefix
  _npm_prefix="$(npm config get prefix 2>/dev/null)"
  # User prefix first — that's where we install into. Then the currently-
  # configured npm prefix (read-only on shared systems), then standard paths.
  for _seg in "$USER_NPM_PREFIX/bin" \
              "${_npm_prefix:+${_npm_prefix}/bin}" \
              "$HOME/.npm-global/bin" \
              /usr/local/bin /opt/homebrew/bin /usr/bin; do
    [ -n "$_seg" ] || continue
    if [ -x "$_seg/codex" ]; then
      # Resolve symlinks; de-dup by resolved path so symlinks that all point
      # to the same target don't get counted as separate installs.
      local _resolved
      _resolved="$(readlink -f "$_seg/codex" 2>/dev/null || echo "$_seg/codex")"
      local _dup=0 _existing
      for _existing in "${_codex_cands[@]}"; do
        [ "$(readlink -f "$_existing" 2>/dev/null || echo "$_existing")" = "$_resolved" ] && _dup=1 && break
      done
      [ "$_dup" = "1" ] || _codex_cands+=("$_seg/codex")
    fi
  done

  if [ "${#_codex_cands[@]}" -gt 1 ]; then
    log_and_print "    [codex] [WARN] multiple codex installs detected — non-deterministic across machines:"
    for _seg in "${_codex_cands[@]}"; do
      log_and_print "             • $_seg  →  $(readlink -f "$_seg" 2>/dev/null || echo "$_seg")"
    done
    if command -v codex &>/dev/null; then
      log_and_print "             PATH winner: $(command -v codex)"
    fi
    log_and_print "             Keep ONE (recommended: $USER_NPM_PREFIX/bin/codex)."
    log_and_print "             Remove others with: npm uninstall -g @openai/codex (per prefix) or 'sudo rm <path>' for legacy /usr/bin."
  elif [ "${#_codex_cands[@]}" -eq 1 ]; then
    log_and_print "    [OK] codex CLI present -> ${_codex_cands[0]}"
  else
    log_and_print "    Installing @openai/codex to user prefix ($USER_NPM_PREFIX)..."
    run_with_timeout "@openai/codex install" "$NPM_USER_ENV npm install -g @openai/codex < /dev/null" \
      | tail -3 || true
    # Re-scan after install. USER_NPM_PREFIX is where we forced the write.
    local _after=""
    if [ -x "$USER_NPM_PREFIX/bin/codex" ]; then
      _after="$USER_NPM_PREFIX/bin/codex"
    elif command -v codex &>/dev/null; then
      _after="$(command -v codex)"
    fi
    if [ -n "$_after" ]; then
      log_and_print "    [OK] @openai/codex installed -> $_after"
      if [ "$_after" = "$USER_NPM_PREFIX/bin/codex" ] && ! command -v codex &>/dev/null; then
        log_and_print "         (note: $USER_NPM_PREFIX/bin not on live PATH; codex-mcp PATH injection below handles it)"
      fi
    else
      log_and_print "    [WARN] @openai/codex install failed — codex-mcp will not function. See $LOG_FILE"
    fi
  fi

  # codex-gemini-mcp (Byun-jinyoung fork — codex-mcp + antigravity-mcp)
  # The fork shares the npm package name @donghae0414/codex-gemini-mcp with
  # upstream donghae0414, so upstream installs win on PATH unless explicitly
  # uninstalled first. We always run cleanup before (re)install to guarantee
  # the fork is what ends up on disk.
  if verify_codex_gemini_mcp; then
    log_and_print "    [OK] codex-mcp + antigravity-mcp (Byun-jinyoung fork verified)"
  else
    log_and_print "    Cleaning up upstream donghae0414 install (if any)..."
    cleanup_upstream_codex_gemini_mcp
    log_and_print "    Installing/repairing Byun-jinyoung fork (target: $USER_NPM_PREFIX)..."
    # Pass npm_config_prefix into the piped bash so the fork's install.sh
    # (which calls `npm install -g ./<tarball>`) writes into USER_NPM_PREFIX
    # on its FIRST attempt — that skips its sudo-fallback branch entirely
    # and keeps the package inside MY $HOME (mode 0700 via ensure_user_npm_prefix)
    # instead of /usr/local|/opt|/usr where other users on a shared host could
    # read provider configs, model defaults, or any embedded data.
    # `npm prefix -g` inside install.sh also reads this env var, so its
    # post-install path resolution lines up with the actual install location.
    run_with_timeout "codex-gemini-mcp install" \
      "$NPM_USER_ENV curl -sL https://raw.githubusercontent.com/Byun-jinyoung/codex-gemini-mcp/main/install.sh | $NPM_USER_ENV bash" \
      | tail -3 || true
    if verify_codex_gemini_mcp; then
      log_and_print "    [OK] Byun-jinyoung fork installed and verified"
    else
      log_and_print "    [WARN] fork install ran but integrity still failing — see $LOG_FILE"
      log_and_print "           Most likely cause: system-wide /usr/bin/{codex,gemini}-mcp symlinks shadowing fork on PATH"
      log_and_print "           Resolve sudo warnings above, then re-run 'setup.sh sync'."
    fi
  fi
  # gemini-swarm
  # Check via filesystem only — never invoke `gemini` here. Both
  # `gemini --list-extensions` and `gemini extensions install` hang when run
  # inside this script's stdout pipeline (likely an interactive-UI heuristic);
  # isolated invocations are fine. Extensions are stored under
  # ~/.gemini/extensions/<name>, so a directory check is sufficient and never
  # hangs. Fresh install must be done manually:
  #   gemini extensions install https://github.com/tmdgusya/gemini-swarm --consent
  if command -v gemini &>/dev/null; then
    if [ -d "$GEMINI_DIR/extensions/gemini-swarm" ]; then
      log_and_print "    [OK] gemini-swarm installed"
    else
      log_and_print "    [INFO] gemini-swarm not installed — run manually:"
      log_and_print "      gemini extensions install https://github.com/tmdgusya/gemini-swarm --consent"
    fi
  fi
  # OMC patches — only run if (a) OMC's render.js is present and (b) we're
  # on Linux. The patch script uses GNU `sed -i '...'` syntax which is not
  # compatible with BSD sed on macOS (BSD sed requires `sed -i '' '...'`).
  if [ -f "$SCRIPT_DIR/patches/omc/omc-render-model-first.sh" ]; then
    if ! find "$CONFIG_DIR/plugins/cache/omc/oh-my-claudecode" -name render.js -path '*/hud/*' 2>/dev/null | grep -q .; then
      log_and_print "    [SKIP] OMC patches — oh-my-claudecode plugin not installed (or cache not yet materialized)"
    elif [ "$(uname -s)" = "Darwin" ]; then
      log_and_print "    [SKIP] OMC patches — patch script is GNU-sed only (not macOS-compatible)"
    else
      run_with_timeout "OMC patches" "bash '$SCRIPT_DIR/patches/omc/omc-render-model-first.sh'" \
        | sed 's/^/    /' || true
    fi
  fi

  # [8] Claude Code plugins
  log_and_print "[8] Plugins"
  if command -v claude &>/dev/null; then
    log_and_print "    Fetching plugin list..."
    local plugin_list
    plugin_list=$(maybe_timeout 30 claude plugin list < /dev/null 2>&1) || {
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
    # OpenAI official: /codex:review, /codex:adversarial-review, /codex:rescue, etc.
    # Uses the global `codex` CLI + ~/.codex/config.toml. Coexists with codex-mcp.
    install_plugin "codex-plugin-cc" "codex@openai-codex" "openai/codex-plugin-cc" "codex@openai-codex"
  else
    log_and_print "    [SKIP] Claude Code not found"
  fi

  # [9] MCP servers
  log_and_print "[9] MCP servers"
  if command -v claude &>/dev/null; then
    log_and_print "    Fetching MCP list..."
    local mcp_list
    mcp_list=$(maybe_timeout 30 claude mcp list < /dev/null 2>&1) || {
      log_and_print "    [WARN] claude mcp list failed (timeout or error), skipping"
      mcp_list=""
    }
    [ -n "$mcp_list" ] && log_and_print "    MCP list retrieved."

    # Auto-migrate a local-scope MCP entry at the current cwd to user scope.
    # Uses JSON-level access (claude mcp add-json + ~/.claude.json identity
    # check) rather than text scraping + eval — that earlier approach was
    # unsafe (shell injection, args-with-spaces loss, multiline env loss).
    # Aborts on conflict (user already has different payload) and preserves
    # the local entry on any failure.
    migrate_mcp_local_to_user() {
      local name="$1"
      python3 - "$name" "$HOME/.claude.json" "$PWD" << 'PYEOF'
import json, sys, subprocess, os
name, path, cwd = sys.argv[1], sys.argv[2], sys.argv[3]

def warn(msg):
    print(f"    [{name}] [WARN] {msg}")

try:
    data = json.load(open(path))
except (OSError, json.JSONDecodeError) as e:
    warn(f"~/.claude.json unreadable ({e}) — skipping migration")
    sys.exit(1)

projects = data.get('projects') or {}
# Path-key candidates: claude may key projects by raw cwd, realpath, or normpath
candidates = {cwd, os.path.realpath(cwd), os.path.normpath(cwd)}
matches = [k for k in candidates if name in ((projects.get(k) or {}).get('mcpServers') or {})]
if not matches:
    sys.exit(0)
if len(set(matches)) > 1:
    warn(f"ambiguous project key match ({matches}) — manual review needed")
    sys.exit(1)
local_entry = projects[matches[0]]['mcpServers'][name]

user_entry = (data.get('mcpServers') or {}).get(name)
if user_entry is not None and user_entry != local_entry:
    warn("user-scope entry differs from local — local preserved (manual review needed)")
    sys.exit(1)

if user_entry is None:
    proc = subprocess.run(
        ['claude', 'mcp', 'add-json', '--scope', 'user', name, json.dumps(local_entry)],
        capture_output=True, text=True
    )
    if proc.returncode != 0:
        warn(f"add-json failed (rc={proc.returncode}): {(proc.stderr or '').strip()[:200]}")
        sys.exit(1)
    try:
        data2 = json.load(open(path))
    except (OSError, json.JSONDecodeError) as e:
        warn(f"~/.claude.json reread failed ({e}) — local preserved")
        sys.exit(1)
    if (data2.get('mcpServers') or {}).get(name) != local_entry:
        warn("user-scope copy not equal to local after add — local preserved")
        sys.exit(1)

rm = subprocess.run(
    ['claude', 'mcp', 'remove', name, '-s', 'local'],
    capture_output=True, text=True
)
if rm.returncode != 0:
    warn(f"local remove failed: {(rm.stderr or '').strip()[:200]} — duplicate state, manual cleanup needed")
    sys.exit(1)

print(f"    [{name}] [OK] migrated local -> user scope")
PYEOF
    }

    # Register an MCP server with claude. If already registered, also verify
    # that any baked-in env (currently just PATH, which we inject for codex-mcp
    # and antigravity-mcp) matches what `cmd` asks for. If it drifted (the
    # entry was registered by an older setup.sh that didn't inject PATH, or
    # USER_NPM_PREFIX changed across machines), tear down and re-register so
    # the new env takes effect. Without this, a once-registered entry stays
    # frozen forever and `setup.sh sync` cannot heal a broken machine.
    add_mcp() {
      local name="$1" cmd="$2" binary="$3"
      log_and_print "    [$name] checking..."

      local needs_register=0
      if echo "$mcp_list" | grep -q "$name"; then
        # Already registered. Decide if env is current.
        local expected_path="" current_env="" current_path=""
        if [[ "$cmd" == *"-e PATH="* ]]; then
          # Extract PATH=<value> token from the cmd string (value runs up to
          # next whitespace; we never quote PATH in our generated cmd lines).
          expected_path="$(echo "$cmd" | sed -nE 's/.*-e PATH=([^[:space:]]+).*/\1/p')"
        fi
        if [ -n "$expected_path" ]; then
          current_env="$(maybe_timeout 10 claude mcp get "$name" </dev/null 2>/dev/null || true)"
          current_path="$(echo "$current_env" | grep -oE 'PATH=[^[:space:]]+' | head -1 | sed 's/^PATH=//')"
          if [ "$current_path" != "$expected_path" ]; then
            log_and_print "    [$name] env PATH out of date — re-registering"
            log_and_print "             have: ${current_path:-<unset>}"
            log_and_print "             want: $expected_path"
            maybe_timeout 10 claude mcp remove "$name" -s user </dev/null 2>&1 | sed 's/^/      /' || true
            # Also clear any local-scope shadow that would resurface
            maybe_timeout 10 claude mcp remove "$name" -s local </dev/null 2>&1 | sed 's/^/      /' || true
            needs_register=1
          fi
        fi
        if [ "$needs_register" = "0" ]; then
          log_and_print "    [$name] OK — already registered"
          # Detect local-scope shadow and auto-migrate. Earlier setup.sh
          # defaulted to local scope; this preserves env/headers/args via
          # JSON identity.
          if maybe_timeout 10 claude mcp get "$name" </dev/null 2>/dev/null \
               | grep -q 'Scope: Local'; then
            migrate_mcp_local_to_user "$name"
          fi
        fi
      else
        needs_register=1
      fi

      if [ "$needs_register" = "1" ]; then
        if [ -n "$binary" ] && ! command -v "$binary" &>/dev/null; then
          log_and_print "    [$name] SKIP — $binary binary not found"
          return 0
        fi
        log_and_print "    [$name] registering..."
        local result
        if result=$(run_with_timeout "$name mcp add" "$cmd < /dev/null" 2>&1); then
          log_and_print "    [$name] registered successfully (user scope)"
        else
          log_and_print "    [$name] registration failed — see $LOG_FILE"
        fi
      fi
    }

    # All MCPs registered at -s user (Claude default is local — was creating
    # cwd-bound entries that silently shadowed any user-level OAuth/auth state).
    # Stale gemini-mcp entry cleanup: the Byun-jinyoung fork renamed gemini → antigravity,
    # so any pre-existing gemini-mcp MCP entry points to a binary that no longer exists.
    # Remove from both scopes (user + local-at-cwd) before registering the new antigravity-mcp.
    if echo "$mcp_list" | grep -q '^gemini-mcp\b\|^gemini-mcp\s'; then
      log_and_print "    [gemini-mcp] removing stale entry (fork dropped gemini-mcp → antigravity-mcp)"
      maybe_timeout 10 claude mcp remove gemini-mcp -s user </dev/null 2>&1 | sed 's/^/      /' || true
      maybe_timeout 10 claude mcp remove gemini-mcp -s local </dev/null 2>&1 | sed 's/^/      /' || true
      # Refresh mcp_list so subsequent add_mcp grep checks see the removal
      mcp_list=$(maybe_timeout 30 claude mcp list < /dev/null 2>&1) || mcp_list=""
    fi

    # codex-mcp spawns the `codex` CLI from PATH at request time. Claude Code's
    # MCP child process inherits a minimal PATH that often lacks npm-global/bin,
    # so codex-mcp silently fails on machines where `codex` lives there (e.g.
    # @openai/codex installed via `npm i -g`). Inject a PATH that includes
    # npm-global/bin + standard system dirs at registration time so the value is
    # baked into ~/.claude.json and reused on every spawn.
    local NPM_BIN_DIR CODEX_PATH _codex_resolved _codex_dir
    NPM_BIN_DIR=""
    if _npm_prefix_q="$(npm config get prefix 2>/dev/null)" && [ -n "$_npm_prefix_q" ]; then
      NPM_BIN_DIR="${_npm_prefix_q}/bin"
    fi
    # Resolve actual codex location now so it can lead the baked-in PATH —
    # otherwise we hardcode npm/system order and a user's Volta/asdf/nvm shim
    # gets missed. USER_NPM_PREFIX/bin is where we install into in this script.
    _codex_resolved=""
    _codex_dir=""
    if command -v codex &>/dev/null; then
      _codex_resolved="$(command -v codex)"
      _codex_dir="$(dirname "$_codex_resolved")"
    fi
    # Build PATH from non-empty segments only (guard against empty npm prefix
    # turning into bare ":/usr/local/bin..." which means "current dir first").
    # Order: actual codex location → USER_NPM_PREFIX/bin → currently-configured
    # npm prefix bin → ~/.npm-global/bin → standard system dirs.
    CODEX_PATH=""
    for _seg in "$_codex_dir" \
                "$USER_NPM_PREFIX/bin" \
                "$NPM_BIN_DIR" \
                "$HOME/.npm-global/bin" \
                "/usr/local/bin" "/opt/homebrew/bin" "/usr/bin" "/bin"; do
      [ -n "$_seg" ] || continue
      # de-dup
      case ":$CODEX_PATH:" in *":$_seg:"*) continue ;; esac
      [ -z "$CODEX_PATH" ] && CODEX_PATH="$_seg" || CODEX_PATH="${CODEX_PATH}:${_seg}"
    done
    # If live PATH lookup missed it, probe each injected segment.
    if [ -z "$_codex_resolved" ]; then
      IFS=':' read -ra _segs <<<"$CODEX_PATH"
      for _seg in "${_segs[@]}"; do
        if [ -x "$_seg/codex" ]; then _codex_resolved="$_seg/codex"; break; fi
      done
    fi
    if [ -z "$_codex_resolved" ]; then
      log_and_print "    [codex-mcp] [WARN] \`codex\` CLI not findable. Install with: npm i -g @openai/codex"
    else
      log_and_print "    [codex-mcp] codex CLI resolved: $_codex_resolved"
    fi
    add_mcp "codex-mcp" \
      "claude mcp add -s user codex-mcp -e PATH=${CODEX_PATH} -- codex-mcp" \
      "codex-mcp"
    add_mcp "antigravity-mcp" \
      "claude mcp add -s user antigravity-mcp -e PATH=${CODEX_PATH} -- antigravity-mcp" \
      "antigravity-mcp"
    add_mcp "serena" "claude mcp add -s user serena -- uvx --from 'git+https://github.com/oraios/serena' serena start-mcp-server" ""
    add_mcp "supermemory" "claude mcp add -s user --transport http supermemory https://mcp.supermemory.ai/mcp" ""
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

  # [9c] Serena hardening — disable browser auto-launch on MCP start
  # Dashboard stays enabled (useful for debugging via http://localhost:24282/dashboard/),
  # but no browser tab is auto-opened each time serena MCP boots.
  log_and_print "[9c] Serena hardening (web_dashboard_open_on_launch=false)"
  if [ -f "$SERENA_CONFIG" ] && command -v python3 &>/dev/null; then
    python3 - "$SERENA_CONFIG" << 'PYEOF' | sed 's/^/    /'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    print("[WARN] PyYAML missing — skipping. pip install pyyaml")
    sys.exit(0)

path = Path(sys.argv[1])
config = yaml.safe_load(path.read_text()) or {}
if config.get("web_dashboard_open_on_launch") is False:
    print("[OK] web_dashboard_open_on_launch already false")
else:
    # Preserve comments by doing a targeted line edit instead of full yaml.dump
    text = path.read_text()
    if "web_dashboard_open_on_launch:" in text:
        new = []
        for line in text.splitlines():
            if line.startswith("web_dashboard_open_on_launch:"):
                new.append("web_dashboard_open_on_launch: false")
            else:
                new.append(line)
        path.write_text("\n".join(new) + ("\n" if text.endswith("\n") else ""))
    else:
        with path.open("a") as f:
            f.write("\nweb_dashboard_open_on_launch: false\n")
    print("[OK] Set web_dashboard_open_on_launch: false")
PYEOF
  else
    log_and_print "    [SKIP] $SERENA_CONFIG not found or python3 missing"
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
  # RTK hook integrity.
  # rtk >= 0.38 registers the hook by writing
  #   PreToolUse[Bash] -> { "command": "rtk hook claude" }
  # directly into settings.json via `rtk init -g`. There is no longer a
  # separate `rtk-rewrite.sh` shell script. (Older setup.sh wired a custom
  # script path; that whole branch is obsolete in rtk 0.38+.)
  if command -v rtk &>/dev/null; then
    run_with_timeout "RTK init -g" "rtk init -g --auto-patch < /dev/null" | tail -3 || true
    if command -v python3 &>/dev/null; then
      python3 - "$CONFIG_DIR/settings.json" << 'PYEOF' | sed 's/^/    /'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    print("[WARN] settings.json missing — RTK hook check skipped")
    sys.exit(0)
try:
    data = json.loads(p.read_text())
except Exception as e:
    print(f"[WARN] settings.json unparseable ({e})")
    sys.exit(0)
pre = data.get("hooks", {}).get("PreToolUse", [])
wired = any(
    isinstance(e, dict) and e.get("matcher") == "Bash" and any(
        isinstance(h, dict) and h.get("command", "").startswith("rtk hook claude")
        for h in e.get("hooks", [])
    ) for e in pre
)
print("[OK] RTK hook wired (rtk hook claude)" if wired
      else "[WARN] RTK hook not in settings.json — run `rtk init -g` manually")
PYEOF
    fi
  fi
  # RTK for Codex + Gemini (Claude RTK hook wired above)
  if [ -x "$RTK_BIN" ]; then
    run_with_timeout "RTK init Codex" "$RTK_BIN init -g --codex < /dev/null" | tail -1 || true
    run_with_timeout "RTK init Gemini" "$RTK_BIN init -g --gemini --auto-patch < /dev/null" | tail -1 || true
    # `rtk init --gemini` overwrites ~/.gemini/GEMINI.md wholesale with RTK guidance
    # (Gemini has no @-include, so RTK replaces the file instead of appending a ref).
    # This clobbers the Layer A+B assembly from [4b], leaving GEMINI.md ~29 lines.
    # RTK usage notes already live in runtimes/<cli>/tools.md (Layer B), so re-assemble
    # to restore the full file. The RTK *hook* lives in settings.json — assembly never
    # touches it, so the token-rewrite hook stays wired.
    log_and_print "    Re-assembling global rules (rtk init --gemini clobbers GEMINI.md)..."
    assemble_global_rules
  fi
  # Graphify — package name is graphifyy; CLI command is graphify.
  # The graphify CLI is the source of truth for ~/.claude/skills/graphify/SKILL.md
  # (each machine's graphifyy version differs — repo-level SKILL.md would drift).
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
  # Sync the Claude skill from the freshly installed graphify, so the SKILL.md
  # always matches the graphifyy package version on this machine (fixes the
  # "skill 0.5.2 vs package 0.8.11" mismatch warning that fires on every call).
  if command -v graphify &>/dev/null; then
    run_with_timeout "graphify install (claude)" "graphify install --platform claude < /dev/null" \
      | sed 's/^/    /' || true
    # Mirror into ~/.agents/skills so codex/gemini see the same SKILL via their
    # shared agents-skills scan. Replace any prior cc-bootstrap symlink.
    if [ -d "$HOME/.claude/skills/graphify" ]; then
      mkdir -p "$AGENTS_DIR/skills"
      if [ -L "$AGENTS_DIR/skills/graphify" ] || [ -e "$AGENTS_DIR/skills/graphify" ]; then
        rm -rf "$AGENTS_DIR/skills/graphify"
      fi
      ln -s "$HOME/.claude/skills/graphify" "$AGENTS_DIR/skills/graphify"
      log_and_print "    [OK] graphify mirrored to $AGENTS_DIR/skills/graphify"
    fi
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
