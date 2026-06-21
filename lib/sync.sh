# oh-my-agent-env: cmd_sync (sourced by setup.sh)
# Not standalone — relies on globals defined in setup.sh and helpers from
# lib/common.sh (must be sourced first).
#
# cmd_sync is decomposed into ordered phase functions (sync_*) below; the
# orchestrator at the bottom calls them in the original execution order.
# Behavior is unchanged — sections were extracted verbatim. Phase functions
# rely on bash dynamic scope + globals, so they take no arguments.

# [1][2][2b] Claude commands, hooks, rules-enforcement
sync_claude() {
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

  # [2b] Rules-enforcement: compressed-rule file + settings.json hook wiring.
  # rules-core.md is read by inject-core-rules.js at $CONFIG_DIR/rules-core.md.
  if [ -f "$SCRIPT_DIR/runtimes/claude/rules-core.md" ]; then
    make_link "$SCRIPT_DIR/runtimes/claude/rules-core.md" "$CONFIG_DIR/rules-core.md"
  fi
  echo "[2b] Rules-enforcement hooks (settings.json)"
  ensure_rules_enforcement_hooks
}

# [3][3b][4][4b] Codex instructions, Gemini dir, global rule assembly
sync_agent_rules() {
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
}

# [5][6] Shared skills (registry.yaml) + statusline
sync_skills_statusline() {
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

# Prune stale oh-my-agent-env symlinks no longer in the registry, so that
# dropping a runtime from registry.yaml self-cleans on every machine.
# Only oh-my-agent-env-managed symlinks are removed; real dirs / foreign
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
}

# [7] External tools (context-mode, codex CLI, LazyCodex, codex-gemini-mcp fork, OMC patches)
sync_external_tools() {
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
  elif [ "${#_codex_cands[@]}" -eq 1 ] && [ "${_codex_cands[0]}" = "$USER_NPM_PREFIX/bin/codex" ]; then
    log_and_print "    [OK] codex CLI present -> $USER_NPM_PREFIX/bin/codex"
  elif [ "${#_codex_cands[@]}" -eq 1 ]; then
    # Single install but OUTSIDE the canonical user prefix (e.g. /usr/local,
    # /opt/homebrew, /usr) — world-readable system path, policy violation.
    # Auto-RELOCATE (not just warn): uninstall the stray from its own prefix,
    # then force-reinstall into $USER_NPM_PREFIX via NPM_USER_ENV. We use the
    # env override rather than `npm config set prefix` to honor the policy in
    # ensure_user_npm_prefix (never mutate the user's global ~/.npmrc).
    local _stray="${_codex_cands[0]}"
    local _stray_prefix="${_stray%/bin/codex}"
    log_and_print "    [codex] relocating codex from $_stray_prefix to $USER_NPM_PREFIX (policy: user-owned, mode 0700)"
    run_with_timeout "codex uninstall (stray $_stray_prefix)" \
      "npm uninstall -g --prefix '$_stray_prefix' @openai/codex < /dev/null" | tail -2 || true
    local _relocate_warn=0
    if [ -e "$_stray" ]; then
      _relocate_warn=1
      log_and_print "    [codex] [WARN] could not remove $_stray (rc!=0; likely root-owned system prefix)"
      case "$_stray_prefix" in
        /usr/*|/opt/*) log_and_print "             Manual: sudo npm uninstall -g --prefix '$_stray_prefix' @openai/codex" ;;
      esac
    fi
    run_with_timeout "@openai/codex reinstall (user prefix)" \
      "$NPM_USER_ENV npm install -g @openai/codex < /dev/null" | tail -3 || true
    if [ -x "$USER_NPM_PREFIX/bin/codex" ]; then
      if [ "$_relocate_warn" = "1" ]; then
        log_and_print "    [codex] [WARN] codex installed -> $USER_NPM_PREFIX/bin/codex, but stray at $_stray still present — duplicate until you remove it (sudo)"
      else
        log_and_print "    [OK] codex relocated -> $USER_NPM_PREFIX/bin/codex"
      fi
    else
      log_and_print "    [codex] [WARN] relocation failed — see $LOG_FILE; manual: npm_config_prefix='$USER_NPM_PREFIX' npm install -g @openai/codex"
    fi
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

  # LazyCodex — Codex agent harness installed via npx. The public package is
  # lazycodex-ai, but the Codex plugin it registers is omo@sisyphuslabs.
  if verify_lazycodex_codex_plugin; then
    local _lcx_version=""
    _lcx_version="$(find "$CODEX_DIR/plugins/cache/sisyphuslabs/omo" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1 | xargs basename 2>/dev/null || true)"
    log_and_print "    [OK] LazyCodex installed as omo@sisyphuslabs${_lcx_version:+ ($_lcx_version)}"
  elif command -v npm &>/dev/null && command -v codex &>/dev/null; then
    log_and_print "    Installing LazyCodex for Codex (npx lazycodex-ai@latest install --no-tui)..."
    run_with_timeout "LazyCodex install" \
      "$NPM_USER_ENV npx --yes lazycodex-ai@latest install --no-tui < /dev/null" \
      | tail -4 || true
    if verify_lazycodex_codex_plugin; then
      local _lcx_version=""
      _lcx_version="$(find "$CODEX_DIR/plugins/cache/sisyphuslabs/omo" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1 | xargs basename 2>/dev/null || true)"
      log_and_print "    [OK] LazyCodex installed as omo@sisyphuslabs${_lcx_version:+ ($_lcx_version)}"
      log_and_print "         Restart Codex App/CLI and approve omo@sisyphuslabs hooks on first launch."
    else
      log_and_print "    [WARN] LazyCodex install ran but Codex plugin verification failed — see $LOG_FILE"
      log_and_print "           Manual check: codex plugin list | grep 'omo@sisyphuslabs'"
    fi
  else
    log_and_print "    [SKIP] LazyCodex — requires npm and codex CLI"
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
  # gemini-swarm install logic removed 2026-05-25: Gemini CLI is fully deprecated
  # in favor of Antigravity (agy). runtimes/claude/commands/gemini-swarm.md
  # already carries a DEPRECATED notice for the orchestration command.
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
}

# [8][9] Claude Code plugins + MCP servers (incl. local helpers install_plugin/add_mcp/migrate)
sync_plugins_mcp() {
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
            # Preserve any user-added env vars (anything except PATH, which we
            # re-inject below). Without this, ad-hoc keys in ~/.claude.json
            # (e.g. MCP_CODEX_DEFAULT_MODEL) get silently dropped whenever a
            # PATH drift triggers re-register.
            local _preserve_args="" _eline _ek _ev
            while IFS= read -r _eline; do
              [ -z "$_eline" ] && continue
              _ek="${_eline%%=*}"
              _ev="${_eline#*=}"
              case "$_ek" in PATH|"") continue ;; esac
              _preserve_args+=" -e ${_ek}=${_ev}"
              log_and_print "    [$name] preserving env: ${_ek}"
            done < <(echo "$current_env" | sed -nE 's/^[[:space:]]+([A-Z_][A-Z0-9_]*=.*)$/\1/p' | grep -v '^PATH=')
            if [ -n "$_preserve_args" ]; then
              # Inject preserved -e flags just before `-- <binary>` in cmd
              cmd="${cmd/ -- /${_preserve_args} -- }"
            fi
            maybe_timeout 10 claude mcp remove "$name" -s user </dev/null 2>&1 | sed 's/^/      /' || true
            # Also clear any local-scope shadow that would resurface
            maybe_timeout 10 claude mcp remove "$name" -s local </dev/null 2>&1 | sed 's/^/      /' || true
            needs_register=1
          fi
        fi
        # Generic env drift check beyond PATH: extract every `-e KEY=VAL`
        # token from cmd and compare against the live entry. Catches the
        # case where new env keys (e.g. MCP_CODEX_DEFAULT_MODEL) were added
        # in a later setup.sh version but an older registration lacks them.
        # Without this, just adding -e flags to cmd would do nothing for
        # machines that already had codex-mcp registered.
        if [ "$needs_register" = "0" ] && [ -n "$current_env" ]; then
          local _exp_line _ek _ev _cur_v
          while IFS= read -r _exp_line; do
            [ -z "$_exp_line" ] && continue
            _ek="${_exp_line%%=*}"
            _ev="${_exp_line#*=}"
            # PATH already covered above; skip to avoid duplicate work.
            case "$_ek" in PATH|"") continue ;; esac
            _cur_v="$(echo "$current_env" | grep -oE "${_ek}=[^[:space:]]+" | head -1 | sed "s/^${_ek}=//")"
            if [ "$_cur_v" != "$_ev" ]; then
              log_and_print "    [$name] env $_ek out of date — re-registering"
              log_and_print "             have: ${_cur_v:-<unset>}"
              log_and_print "             want: $_ev"
              maybe_timeout 10 claude mcp remove "$name" -s user </dev/null 2>&1 | sed 's/^/      /' || true
              maybe_timeout 10 claude mcp remove "$name" -s local </dev/null 2>&1 | sed 's/^/      /' || true
              needs_register=1
              break
            fi
          done < <(echo "$cmd" | grep -oE '\-e [A-Z_][A-Z0-9_]*=[^[:space:]]+' | sed -E 's/^-e ([A-Z_][A-Z0-9_]*)=(.*)$/\1=\2/')
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
    # antigravity-mcp shells out to the `agy` CLI, which typically installs to
    # ~/.local/bin — a dir NOT covered by the npm/system segments below. Without
    # agy's dir in the baked PATH, antigravity-mcp starts (stdio handshake ok, so
    # doctor reports OK) but every antigravity call fails with `agy` ENOENT,
    # silently breaking triangle-review/debate-loop/analyze-paper. Resolve agy's
    # dir (and include ~/.local/bin generally) so the injected PATH can find it.
    local _agy_dir=""
    if command -v agy &>/dev/null; then _agy_dir="$(dirname "$(command -v agy)")"; fi
    # Build PATH from non-empty segments only (guard against empty npm prefix
    # turning into bare ":/usr/local/bin..." which means "current dir first").
    # Order: actual codex location → USER_NPM_PREFIX/bin → currently-configured
    # npm prefix bin → ~/.npm-global/bin → standard system dirs.
    CODEX_PATH=""
    for _seg in "$_codex_dir" \
                "$USER_NPM_PREFIX/bin" \
                "$NPM_BIN_DIR" \
                "$HOME/.npm-global/bin" \
                "$_agy_dir" \
                "$HOME/.local/bin" \
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
    # Default codex model for the MCP. Fork hardcodes gpt-5.3-codex which is
    # not available on every ChatGPT plan (exit 1 on first call). Override via
    # MCP_CODEX_DEFAULT_MODEL env, which fork's dist/config.js getDefaultModel()
    # reads at request time. Allow per-machine override via CC_BOOTSTRAP_CODEX_MODEL.
    local CODEX_DEFAULT_MODEL="${CC_BOOTSTRAP_CODEX_MODEL:-gpt-5.5}"
    add_mcp "codex-mcp" \
      "claude mcp add -s user codex-mcp -e PATH=${CODEX_PATH} -e MCP_CODEX_DEFAULT_MODEL=${CODEX_DEFAULT_MODEL} -- codex-mcp" \
      "codex-mcp"
    add_mcp "antigravity-mcp" \
      "claude mcp add -s user antigravity-mcp -e PATH=${CODEX_PATH} -- antigravity-mcp" \
      "antigravity-mcp"
    add_mcp "serena" "claude mcp add -s user serena -- uvx --from 'git+https://github.com/oraios/serena' serena start-mcp-server" ""
    add_mcp "supermemory" "claude mcp add -s user --transport http supermemory https://mcp.supermemory.ai/mcp" ""
  fi
}

# [9b][9c][10] Codex/Antigravity MCP entries, Serena hardening, frameworks (GSD/RTK/Graphify/CRG/codegraph)
sync_agent_mcp_frameworks() {
  # [9b] Codex / Antigravity MCP registration (for triangle-review + codebase-scan)
  # serena와 code-review-graph는 ~/.codex/config.toml과
  # ~/.gemini/config/mcp_config.json에 별도 등록되어야 함
  # (claude mcp add는 Claude Code에만 등록됨; agy CLI/IDE는 ~/.gemini/config/
  # mcp_config.json을 shared MCP source of truth로 본다 — top-level
  # ~/.gemini/settings.json mcpServers는 안 본다.)
  log_and_print "[9b] Codex/Antigravity MCP entries"
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

# --- Antigravity (shared MCP config at ~/.gemini/config/mcp_config.json) ---
# agy CLI and Antigravity IDE both read this file as the global/shared
# source of truth for MCP servers (per official Antigravity docs and
# verified via /mcp output). ~/.gemini/settings.json mcpServers (the
# pre-2026-05-19 gemini-cli location) is NOT picked up by agy.
# Hooks below still write to ~/.gemini/settings.json because context-mode's
# hook system was built for the gemini-cli hook schema; that's a separate
# concern from MCP routing.
agy_mcp_cfg = Path(gemini_dir) / "config" / "mcp_config.json"
agy_mcp_cfg.parent.mkdir(parents=True, exist_ok=True)
agy_data = {}
if agy_mcp_cfg.exists() and agy_mcp_cfg.stat().st_size > 0:
    try:
        agy_data = json.loads(agy_mcp_cfg.read_text())
    except json.JSONDecodeError:
        print(f"[WARN] {agy_mcp_cfg} unparseable — skipping mcp register (back up + edit manually)")
        agy_data = None

# settings.json is still loaded for the hooks block that follows
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

added_gemini = []
if agy_data is not None:
    mcp_servers = agy_data.setdefault("mcpServers", {})

    # Step 1: preserve any third-party mcpServers that were in the legacy
    # ~/.gemini/settings.json. Merge them into the new shared location BEFORE
    # stripping the legacy key, so user-managed entries (e.g. agentmemory)
    # don't get lost. oh-my-agent-env-managed entries (WANTED below) win on
    # conflict — they always reflect the canonical spec.
    legacy_mcp = data.get("mcpServers", {}) if isinstance(data, dict) else {}
    preserved = []
    for name, spec in legacy_mcp.items():
        if name not in mcp_servers:
            mcp_servers[name] = spec
            preserved.append(name)

    # Step 2: apply oh-my-agent-env's WANTED entries (overwrites legacy entries
    # of the same name with the canonical spec).
    for name, spec in WANTED.items():
        # Force update context-mode to ensure absolute path integrity
        if name == "context-mode" and cm_path:
            new_spec = {"command": "node", "args": [cm_path]}
            if mcp_servers.get(name) != new_spec:
                mcp_servers[name] = new_spec
                added_gemini.append(name)
            continue

        if name in mcp_servers and name not in preserved:
            continue
        mcp_servers[name] = spec
        added_gemini.append(name)

    agy_mcp_cfg.write_text(json.dumps(agy_data, indent=2))

    # Step 3: strip the now-redundant mcpServers from the legacy settings.json.
    # agy and Antigravity IDE don't read this location for MCPs anyway; leaving
    # the entries there is misleading on doctor output and on future debugging.
    if legacy_mcp:
        del data["mcpServers"]
        moved_label = (", ".join(legacy_mcp.keys())) or "(none)"
        if preserved:
            print(f"[OK] preserved third-party mcpServers ({', '.join(preserved)}) during migration")
        print(f"[OK] migrated mcpServers ({moved_label}) out of {gemini_cfg.name} into config/mcp_config.json")

# --- Strip oh-my-agent-env-managed gemini-cli hooks from legacy settings.json ---
# agy does not read settings.json hooks (verified: 0 fires across agy logs;
# import_manifest excludes hooks). The Gemini CLI does still read this file,
# but the user's policy is full transition to agy. So we stop writing
# context-mode gemini-cli hooks here and selectively strip any we previously
# wrote. Third-party hook entries (e.g., RTK's rtk-hook-gemini.sh) are
# preserved — the mcpServers regression taught us not to nuke the whole key.
hooks_data = data.get("hooks", {})
stripped = []
if isinstance(hooks_data, dict):
    for event in list(hooks_data.keys()):
        wrappers = hooks_data.get(event, [])
        if not isinstance(wrappers, list):
            continue
        new_wrappers = []
        for w in wrappers:
            if not isinstance(w, dict):
                new_wrappers.append(w)
                continue
            hs = w.get("hooks", [])
            kept = [h for h in hs
                    if not (isinstance(h, dict)
                            and "context-mode hook gemini-cli" in str(h.get("command", "")))]
            if not kept:
                # entire wrapper was a oh-my-agent-env entry — drop it
                stripped.append(f"{event}")
                continue
            if len(kept) != len(hs):
                w["hooks"] = kept
                stripped.append(f"{event}(partial)")
            new_wrappers.append(w)
        if new_wrappers:
            hooks_data[event] = new_wrappers
        else:
            del hooks_data[event]
    if not hooks_data:
        data.pop("hooks", None)

# Write back if mcpServers strip OR hooks strip changed anything
if bool(legacy_mcp) or stripped:
    gemini_cfg.write_text(json.dumps(data, indent=2, ensure_ascii=False))

if stripped:
    print(f"[OK] stripped oh-my-agent-env-managed gemini-cli hooks ({', '.join(stripped)}) from settings.json — agy ignores them; gemini-cli still reads any remaining hooks")
elif not legacy_mcp:
    print("[OK] Gemini: settings.json already clean")
PYEOF
  else
    log_and_print "    [SKIP] python3 not available"
  fi
  if command -v context-mode &>/dev/null; then
    ensure_codex_context_mode
  else
    log_and_print "    [WARN] context-mode missing. Install Node package first: npm install -g context-mode"
  fi
  # Harden the other Codex-side managed MCPs (serena/code-review-graph/antigravity-mcp)
  # with absolute command + env PATH so they resolve under Codex's spawn PATH.
  ensure_codex_mcp_paths

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
  # rtk >= 0.38 is REQUIRED: that's when `rtk hook claude` (the hook command the
  # init + doctor logic below expect) was introduced. An older binary already on
  # PATH (e.g. 0.31, which writes a different hook form) must be UPGRADED, not
  # just skipped — otherwise `rtk init -g` keeps installing the old hook form and
  # the doctor RTK-hook check WARNs forever. rtk has no self-update subcommand,
  # so re-running the upstream install.sh is the upgrade path.
  RTK_BIN="$HOME/.local/bin/rtk"
  RTK_MIN_VERSION="0.38.0"
  # Returns 0 if "$1" >= RTK_MIN_VERSION (sort -V: lowest of {min,ver} == min ⇒ ver>=min).
  rtk_version_ok() {
    local ver="$1"
    [ -n "$ver" ] || return 1
    [ "$(printf '%s\n%s\n' "$RTK_MIN_VERSION" "$ver" | sort -V | head -1)" = "$RTK_MIN_VERSION" ]
  }
  rtk_install_upstream() {
    run_with_timeout "RTK install" \
      "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh" \
      | tail -3 || true
    export PATH="$HOME/.local/bin:$PATH"
  }
  if [ -x "$RTK_BIN" ]; then
    _rtk_cur="$("$RTK_BIN" --version 2>/dev/null | awk '{print $2}')"
    if rtk_version_ok "$_rtk_cur"; then
      log_and_print "    [OK] RTK $_rtk_cur (>= $RTK_MIN_VERSION)"
    else
      log_and_print "    RTK ${_rtk_cur:-unknown} < $RTK_MIN_VERSION — upgrading (need 'rtk hook claude' form)..."
      rtk_install_upstream
      _rtk_new="$(rtk --version 2>/dev/null | awk '{print $2}')"
      if rtk_version_ok "$_rtk_new"; then
        log_and_print "    [OK] RTK upgraded: $_rtk_new"
      else
        log_and_print "    [WARN] RTK still ${_rtk_new:-unknown} after upgrade (need >= $RTK_MIN_VERSION). See https://github.com/rtk-ai/rtk"
      fi
    fi
  else
    log_and_print "    Installing RTK..."
    rtk_install_upstream
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
    # shared agents-skills scan. Replace any prior oh-my-agent-env symlink.
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

  # codegraph — used by codebase-scan skill for symbol-level queries via MCP.
  # Node-based; install through npm into the user-owned prefix that
  # ensure_user_npm_prefix established at the top of doctor/sync.
  if command -v codegraph &>/dev/null; then
    log_and_print "    [OK] codegraph $(codegraph --version 2>&1 | head -1)"
  elif command -v npm &>/dev/null; then
    log_and_print "    Installing codegraph (npm -g)..."
    run_with_timeout "codegraph install (npm)" "npm i -g @colbymchenry/codegraph < /dev/null" \
      | tail -2 || true
    if command -v codegraph &>/dev/null; then
      log_and_print "    [OK] codegraph installed: $(codegraph --version 2>&1 | head -1)"
    else
      log_and_print "    [WARN] codegraph install via npm failed — see $LOG_FILE"
    fi
  else
    log_and_print "    [WARN] codegraph missing. Install Node.js + npm, then: npm i -g @colbymchenry/codegraph"
  fi
}

cmd_sync() {
  log "=== oh-my-agent-env sync started ==="
  log "  Platform: $(uname -s) $(uname -m)"
  log "  Shell: $SHELL"
  log "  PATH: $PATH"
  echo "=== oh-my-agent-env sync ==="
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

  sync_claude
  sync_agent_rules
  sync_skills_statusline

  # Network-dependent steps (skip with --skip-network)
  if $SKIP_NETWORK; then
    log_and_print "[7-10] Skipped (--skip-network)"
    log "=== sync complete (network steps skipped) ==="
    echo ""
    echo "=== sync complete (network steps skipped). Restart Claude Code to apply. ==="
    echo "  Full log: $LOG_FILE"
    return
  fi

  sync_external_tools
  sync_plugins_mcp
  sync_agent_mcp_frameworks

  log "=== sync complete ==="
  echo ""
  echo "=== sync complete. Restart Claude Code to apply. ==="
  echo "  Full log: $LOG_FILE"
}
