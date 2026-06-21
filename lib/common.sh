# oh-my-agent-env: shared helpers (sourced by setup.sh)
# Not standalone — relies on globals defined in setup.sh:
#   SCRIPT_DIR, CONFIG_DIR, CODEX_DIR, AGENTS_DIR, GEMINI_DIR,
#   LOG_FILE, STEP_TIMEOUT, USER_NPM_PREFIX (set by ensure_user_npm_prefix).
# Contains: log, log_and_print, maybe_timeout, run_with_timeout,
#   ensure_user_npm_prefix, make_link, verify_codex_gemini_mcp,
#   cleanup_upstream_codex_gemini_mcp, verify_lazycodex_codex_plugin,
#   mcp_spawn_check,
#   append_section_if_missing, ensure_line_in_file,
#   ensure_codex_multi_agent, ensure_codex_context_mode,
#   write_graphify_project_config,
#   assemble_global_rules.

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

# Verify LazyCodex is installed as the Codex plugin it actually registers:
# omo@sisyphuslabs. LazyCodex's public installer is an npx alias; Codex sees
# the installed payload as the OMO plugin namespace under the sisyphuslabs
# marketplace.
verify_lazycodex_codex_plugin() {
  command -v codex &>/dev/null || return 1

  local plugin_root="$CODEX_DIR/plugins/cache/sisyphuslabs/omo"
  local installed_root=""
  if [ -d "$plugin_root" ]; then
    installed_root="$(find "$plugin_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)"
  fi
  [ -n "$installed_root" ] || return 1
  [ -f "$installed_root/.codex-plugin/plugin.json" ] || return 1
  [ -d "$installed_root/skills" ] || return 1
  [ -f "$installed_root/.mcp.json" ] || return 1

  if maybe_timeout 30 codex plugin list </dev/null 2>/dev/null | grep -qE 'omo@sisyphuslabs[[:space:]]+installed, enabled'; then
    return 0
  fi
  return 1
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
  # Codex spawns MCP servers / hooks with its own inherited PATH (the codex npm
  # wrapper does NOT build a login-shell PATH). On machines where context-mode
  # lives only in a user npm prefix (e.g. ~/.npm-global/bin on Linux) that dir is
  # often absent from codex's spawn PATH, so a bare `command = "context-mode"`
  # entry fails with ENOENT and the MCP never starts (hooks likewise). macOS
  # happened to work only because context-mode resolved under /usr/local/bin.
  # Fix: bake the ABSOLUTE context-mode path into config.toml + hooks, and inject
  # a PATH env (incl. node's dir, for the `#!/usr/bin/env node` shebang). Resolved
  # fresh every sync so it self-heals across machines. We do targeted TOML/JSON
  # edits (never `codex mcp add/remove`) to preserve user-added subsections like
  # [mcp_servers.context-mode.tools.*].
  local _cm_bin _node_bin _cm_dir _node_dir _baked _d
  _cm_bin="$(command -v context-mode 2>/dev/null)"
  if [ -z "$_cm_bin" ]; then
    log_and_print "    [SKIP] context-mode not on PATH — cannot wire Codex context-mode"
    return
  fi
  _node_bin="$(command -v node 2>/dev/null)"
  _cm_dir="$(dirname "$_cm_bin")"
  _node_dir="$(dirname "$_node_bin")"
  _baked="$_cm_dir"
  for _d in "$_node_dir" /usr/local/bin /usr/bin /bin; do
    [ -n "$_d" ] || continue
    case ":$_baked:" in *":$_d:"*) ;; *) _baked="$_baked:$_d" ;; esac
  done
  CM_BIN="$_cm_bin" CM_PATH="$_baked" node << 'JSEOF' | sed 's/^/    /'
const fs = require("fs");
const os = require("os");
const path = require("path");

const cmBin = process.env.CM_BIN || "context-mode";
const bakedPath = process.env.CM_PATH || "";

const codexDir = path.join(os.homedir(), ".codex");
fs.mkdirSync(codexDir, { recursive: true });

// ---- config.toml: set absolute command + env.PATH on [mcp_servers.context-mode],
//      preserving every other table (incl. .tools.* subsections). ----
const cfg = path.join(codexDir, "config.toml");
let content = fs.existsSync(cfg) ? fs.readFileSync(cfg, "utf8") : "";
let lines = content.length ? content.split("\n") : [];

const MAIN = "mcp_servers.context-mode";
const ENVT = "mcp_servers.context-mode.env";
const desiredCmd = `command = "${cmBin}"`;
const desiredPath = `PATH = "${bakedPath}"`;

const isHeader = (l) => /^\s*\[/.test(l);
const headerName = (l) => { const m = l.match(/^\s*\[(.+?)\]\s*$/); return m ? m[1].trim() : null; };
const bodyEndFrom = (start) => { for (let i = start; i < lines.length; i++) if (isHeader(lines[i])) return i; return lines.length; };

let changed = false;
let mainIdx = lines.findIndex((l) => headerName(l) === MAIN);

if (mainIdx === -1) {
  if (content.length && !content.endsWith("\n")) lines.push("");
  lines.push("", `[${MAIN}]`, desiredCmd, "", `[${ENVT}]`, desiredPath);
  changed = true;
} else {
  // command line inside the main table body
  let end = bodyEndFrom(mainIdx + 1);
  let cmdLine = -1;
  for (let i = mainIdx + 1; i < end; i++) if (/^\s*command\s*=/.test(lines[i])) { cmdLine = i; break; }
  if (cmdLine === -1) { lines.splice(mainIdx + 1, 0, desiredCmd); changed = true; }
  else if (lines[cmdLine].trim() !== desiredCmd) { lines[cmdLine] = desiredCmd; changed = true; }

  // ensure [..env] table with PATH
  let envIdx = lines.findIndex((l) => headerName(l) === ENVT);
  if (envIdx === -1) {
    const insAt = bodyEndFrom(mainIdx + 1);
    lines.splice(insAt, 0, `[${ENVT}]`, desiredPath, "");
    changed = true;
  } else {
    let eend = bodyEndFrom(envIdx + 1);
    let pLine = -1;
    for (let i = envIdx + 1; i < eend; i++) if (/^\s*PATH\s*=/.test(lines[i])) { pLine = i; break; }
    if (pLine === -1) { lines.splice(envIdx + 1, 0, desiredPath); changed = true; }
    else if (lines[pLine].trim() !== desiredPath) { lines[pLine] = desiredPath; changed = true; }
  }
}

if (changed) {
  fs.writeFileSync(cfg, lines.join("\n").replace(/^\n+/, "").replace(/\n+$/, "") + "\n");
  console.log("[OK] Codex: context-mode MCP command(abs)+env.PATH set in config.toml");
} else {
  console.log("[OK] Codex: context-mode MCP command+env.PATH already correct");
}

// ---- hooks.json: wrap each command with /usr/bin/env PATH=... <abs> so the
//      hook executable + its node shebang resolve regardless of codex spawn PATH.
const hooksPath = path.join(codexDir, "hooks.json");
let data = {};
if (fs.existsSync(hooksPath)) {
  try {
    data = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  } catch {
    const backup = `${hooksPath}.bak.${Date.now()}`;
    fs.copyFileSync(hooksPath, backup);
    console.log(`[WARN] Codex: hooks.json invalid; backed up to ${backup}`);
    data = {};
  }
}
data.hooks = data.hooks || {};
const mkCmd = (tok) => `/usr/bin/env PATH=${bakedPath} ${cmBin} hook codex ${tok}`;
const wanted = {
  PreToolUse: {
    token: "pretooluse",
    matcher: "local_shell|shell|shell_command|exec_command|container.exec|Bash|Shell|grep_files|mcp__plugin_context-mode_context-mode__ctx_execute|mcp__plugin_context-mode_context-mode__ctx_execute_file|mcp__plugin_context-mode_context-mode__ctx_batch_execute",
  },
  PostToolUse: { token: "posttooluse" },
  SessionStart: { token: "sessionstart" },
  UserPromptSubmit: { token: "userpromptsubmit" },
  Stop: { token: "stop" },
};
for (const [event, spec] of Object.entries(wanted)) {
  const existing = Array.isArray(data.hooks[event]) ? data.hooks[event] : [];
  // Remove ANY prior context-mode hook for this event (bare or wrapped) by its
  // stable marker, so re-running upgrades old entries instead of duplicating.
  const marker = `hook codex ${spec.token}`;
  const filtered = existing.filter((entry) => !JSON.stringify(entry).includes(marker));
  const entry = { hooks: [{ type: "command", command: mkCmd(spec.token) }] };
  if (spec.matcher) entry.matcher = spec.matcher;
  filtered.push(entry);
  data.hooks[event] = filtered;
}
fs.writeFileSync(hooksPath, JSON.stringify(data, null, 2) + "\n");
console.log("[OK] Codex: context-mode hooks set (env-wrapped, abs path) in hooks.json");
// ~/.codex/AGENTS.md is assembled by assemble_global_rules (Layer A + Layer B);
// context-mode routing lives in runtimes/codex/tools.md.
JSEOF
}

ensure_codex_mcp_paths() {
  # Same root cause as the context-mode fix, generalized to the other Codex-side
  # managed MCP servers: Codex spawns MCP servers with its inherited process PATH
  # (no login-shell PATH). serena (command=uvx), code-review-graph, and
  # antigravity-mcp (which itself shells out to `agy`) live in ~/.local/bin or
  # ~/.npm-global/bin — often absent from Codex's spawn PATH, so a bare command
  # fails to start the server (or antigravity starts but hits `agy` ENOENT).
  # Set an ABSOLUTE command + [..env] PATH on each, preserving args / .tools.*
  # subsections / other servers. Created if absent (antigravity-mcp). Idempotent,
  # resolved fresh each sync. context-mode is handled by ensure_codex_context_mode.
  command -v node &>/dev/null || { log_and_print "    [SKIP] node not available — codex MCP PATH hardening"; return; }
  local _seg _baked="" _node_dir=""
  command -v node &>/dev/null && _node_dir="$(dirname "$(command -v node)")"
  for _seg in "$HOME/.local/bin" "$HOME/.npm-global/bin" "${USER_NPM_PREFIX:+$USER_NPM_PREFIX/bin}" "$_node_dir" /usr/local/bin /opt/homebrew/bin /usr/bin /bin; do
    [ -n "$_seg" ] || continue
    case ":$_baked:" in *":$_seg:"*) ;; *) _baked="${_baked:+$_baked:}$_seg" ;; esac
  done
  # name:lookup-binary for each managed server (serena's command is uvx).
  local _specs="" _pair _name _bin _abs
  for _pair in "serena:uvx" "code-review-graph:code-review-graph" "antigravity-mcp:antigravity-mcp"; do
    _name="${_pair%%:*}"; _bin="${_pair##*:}"
    _abs="$(command -v "$_bin" 2>/dev/null)"
    # Fallback: the sync shell's PATH may lack ~/.local/bin even though _baked
    # includes it — probe the baked dirs so we still harden the server.
    if [ -z "$_abs" ]; then
      local _bd
      IFS=':' read -ra _bd <<<"$_baked"
      for _seg in "${_bd[@]}"; do [ -x "$_seg/$_bin" ] && { _abs="$_seg/$_bin"; break; }; done
    fi
    [ -n "$_abs" ] && _specs="${_specs}${_name}	${_abs}
"
  done
  [ -n "$_specs" ] || { log_and_print "    [SKIP] no codex-managed MCP binaries resolvable"; return; }
  CMCP_PATH="$_baked" CMCP_SPECS="$_specs" node << 'JSEOF' | sed 's/^/    /'
const fs = require("fs");
const os = require("os");
const path = require("path");

const baked = process.env.CMCP_PATH || "";
const specs = (process.env.CMCP_SPECS || "").split("\n").map((l) => l.trim()).filter(Boolean)
  .map((l) => { const [name, cmd] = l.split("\t"); return { name, cmd }; });

const cfg = path.join(os.homedir(), ".codex", "config.toml");
let content = fs.existsSync(cfg) ? fs.readFileSync(cfg, "utf8") : "";
let lines = content.length ? content.split("\n") : [];

const isHeader = (l) => /^\s*\[/.test(l);
const headerName = (l) => { const m = l.match(/^\s*\[(.+?)\]\s*$/); return m ? m[1].trim() : null; };
const bodyEndFrom = (start) => { for (let i = start; i < lines.length; i++) if (isHeader(lines[i])) return i; return lines.length; };

let changed = false;
for (const { name, cmd } of specs) {
  const MAIN = `mcp_servers.${name}`;
  const ENVT = `mcp_servers.${name}.env`;
  const dCmd = `command = "${cmd}"`;
  const dPath = `PATH = "${baked}"`;
  let mi = lines.findIndex((l) => headerName(l) === MAIN);
  if (mi === -1) {
    if (lines.length && lines[lines.length - 1].trim() !== "") lines.push("");
    lines.push(`[${MAIN}]`, dCmd, "", `[${ENVT}]`, dPath, "");
    changed = true;
    continue;
  }
  let end = bodyEndFrom(mi + 1);
  let ci = -1;
  for (let i = mi + 1; i < end; i++) if (/^\s*command\s*=/.test(lines[i])) { ci = i; break; }
  if (ci === -1) { lines.splice(mi + 1, 0, dCmd); changed = true; }
  else if (lines[ci].trim() !== dCmd) { lines[ci] = dCmd; changed = true; }

  let ei = lines.findIndex((l) => headerName(l) === ENVT);
  if (ei === -1) {
    const insAt = bodyEndFrom(mi + 1);
    lines.splice(insAt, 0, `[${ENVT}]`, dPath, "");
    changed = true;
  } else {
    let ee = bodyEndFrom(ei + 1);
    let pi = -1;
    for (let i = ei + 1; i < ee; i++) if (/^\s*PATH\s*=/.test(lines[i])) { pi = i; break; }
    if (pi === -1) { lines.splice(ei + 1, 0, dPath); changed = true; }
    else if (lines[pi].trim() !== dPath) { lines[pi] = dPath; changed = true; }
  }
}

if (changed) {
  fs.writeFileSync(cfg, lines.join("\n").replace(/^\n+/, "").replace(/\n+$/, "") + "\n");
  console.log("[OK] Codex: managed MCP command(abs)+env.PATH hardened (" + specs.map((s) => s.name).join(", ") + ")");
} else {
  console.log("[OK] Codex: managed MCP command+env.PATH already correct");
}
JSEOF
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

# Register the rules-enforcement hooks (compressed-rule injection + pre-edit
# checklist + edit-turn verify gate) into Claude's global settings.json.
# Idempotent + non-destructive: merges only its own entries, preserves all
# existing hooks (RTK PreToolUse[Bash], gsd, user-added). Detects prior
# registration by script basename so re-running sync is a no-op. The hook
# SCRIPTS themselves are symlinked separately by cmd_sync's [2] Claude hooks
# step ($CONFIG_DIR/hooks/<name>); this only wires settings.json to call them.
ensure_rules_enforcement_hooks() {
  command -v python3 &>/dev/null || { log_and_print "    [SKIP] python3 missing — rules-enforcement hooks"; return; }
  python3 - "$CONFIG_DIR" << 'PYEOF' | sed 's/^/    /'
import json, sys, shutil
from pathlib import Path

config_dir = Path(sys.argv[1])
settings = config_dir / "settings.json"
hooks_dir = config_dir / "hooks"

# (event, matcher_or_None, script_basename)
WANT = [
    ("UserPromptSubmit", None, "inject-core-rules.js"),
    ("Stop", None, "stop-verify-gate.js"),
    ("PreToolUse", "Edit|Write|MultiEdit|NotebookEdit", "pre-edit-gate.js"),
]

if settings.exists():
    try:
        data = json.loads(settings.read_text())
    except json.JSONDecodeError:
        print("[WARN] settings.json unparseable — skipping rules-enforcement hooks (edit manually)")
        sys.exit(0)
else:
    data = {}

hooks = data.setdefault("hooks", {})
changed = []
for event, matcher, script in WANT:
    arr = hooks.setdefault(event, [])
    if not isinstance(arr, list):
        continue
    already = any(
        isinstance(h, dict)
        and any(isinstance(x, dict) and script in str(x.get("command", "")) for x in h.get("hooks", []))
        for h in arr
    )
    if already:
        continue
    cmd = f'node "{hooks_dir}/{script}"'
    entry = {"hooks": [{"type": "command", "command": cmd}]}
    if matcher:
        entry = {"matcher": matcher, "hooks": [{"type": "command", "command": cmd}]}
    arr.append(entry)
    changed.append(f"{event}:{script}")

if changed:
    bak = settings.parent / (settings.name + ".bak.rules-enforcement")
    if settings.exists() and not bak.exists():
        shutil.copyfile(settings, bak)
        print(f"[BACKUP] {bak.name}")
    settings.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(f"[OK] rules-enforcement hooks registered: {', '.join(changed)}")
else:
    print("[OK] rules-enforcement hooks already registered")
PYEOF
}
