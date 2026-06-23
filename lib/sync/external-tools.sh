# oh-my-agent-env: sync domain - external-tools.sh
# Sourced by lib/sync.sh; not standalone.

# [7] External tools (context-mode, codex CLI, LazyCodex, codex-gemini-mcp fork)
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
  # cc-alchemy-statusline — usage tracker that powers the 5h/wk bars + reset
  # countdown in ui/statusline/my-statusline.mjs. my-statusline shells out to
  # `cc-alchemy-statusline --fetch-only` to keep the rate-limit cache fresh;
  # without it the reset countdowns go stale (show no "(…)"). npm global pkg.
  if command -v cc-alchemy-statusline &>/dev/null; then
    log_and_print "    [OK] cc-alchemy-statusline installed"
  else
    log_and_print "    Installing cc-alchemy-statusline (npm global → $USER_NPM_PREFIX)..."
    run_with_timeout "cc-alchemy-statusline install" "$NPM_USER_ENV npm install -g cc-alchemy-statusline < /dev/null" \
      | tail -3 || true
    if command -v cc-alchemy-statusline &>/dev/null; then
      log_and_print "    [OK] cc-alchemy-statusline installed -> $(command -v cc-alchemy-statusline)"
    else
      log_and_print "    [WARN] cc-alchemy-statusline still not on PATH after install — statusline reset countdown will be stale."
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
}
