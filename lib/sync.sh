# oh-my-agent-env: cmd_sync orchestrator (sourced by setup.sh)
# Not standalone — relies on globals defined in setup.sh and helpers from
# lib/common.sh (must be sourced first).
#
# The domain functions live under lib/sync/*.sh. Keep cmd_sync here as the
# public sync command boundary so setup.sh dispatch and phase order stay stable.
# shellcheck shell=bash   # sourced fragment: no shebang by design

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sync/core.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sync/rules.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sync/skills.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sync/external-tools.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sync/plugins-mcp.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sync/frameworks.sh"

# The closing line is the only part of a long sync most people read, and it
# used to say "complete" unconditionally — including on the runs where a domain
# had just reported that the three CLIs no longer share one rule set. Anything
# that increments ERRORS now reaches the last line the user sees.
sync_closing_line() {
  if [ "${ERRORS:-0}" -gt 0 ]; then
    echo "=== sync finished with ${ERRORS} problem(s) — search the log for [FAIL] ==="
  else
    echo "=== $1 ==="
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
    sync_closing_line "sync complete (network steps skipped). Restart Claude Code to apply."
    echo "  Full log: $LOG_FILE"
    return
  fi

  sync_external_tools
  sync_plugins_mcp
  sync_agent_mcp_frameworks

  log "=== sync complete ==="
  echo ""
  sync_closing_line "sync complete. Restart Claude Code to apply."
  echo "  Full log: $LOG_FILE"
}
