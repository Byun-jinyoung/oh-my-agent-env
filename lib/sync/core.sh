# oh-my-agent-env: sync domain - core.sh
# Sourced by lib/sync.sh; not standalone.

# [1][2][2b] Claude commands, hooks, rules-enforcement
sync_claude() {
  # Claude commands
  echo "[1] Claude commands"
  mkdir -p "$CONFIG_DIR/commands"
  for f in "$SCRIPT_DIR/runtimes/claude/commands/"*.md; do
    [ -f "$f" ] && make_link "$f" "$CONFIG_DIR/commands/$(basename "$f")"
  done

  # Claude hooks — manifest-driven. The manifest is the single source of truth
  # shared with ensure_rules_enforcement_hooks, so a hook can never be installed
  # as a file without also being wired into settings.json (and vice versa). A
  # bare glob used to link test fixtures (test-*.js) into the live hooks dir too.
  local hooks_src="$SCRIPT_DIR/runtimes/claude/hooks"
  if [ -d "$hooks_src" ]; then
    echo "[2] Claude hooks"
    mkdir -p "$CONFIG_DIR/hooks"
    local script
    while IFS= read -r script; do
      [ -n "$script" ] || continue
      if [ -f "$hooks_src/$script" ]; then
        make_link "$hooks_src/$script" "$CONFIG_DIR/hooks/$script"
      else
        log_and_print "    [WARN] manifest lists $script but $hooks_src/$script is missing"
      fi
    done < <(hook_manifest_scripts)
  fi

  # [2b] Rules-enforcement: compressed-rule file + settings.json hook wiring.
  # rules-core.md is read by inject-core-rules.js at $CONFIG_DIR/rules-core.md.
  if [ -f "$SCRIPT_DIR/runtimes/claude/rules-core.md" ]; then
    make_link "$SCRIPT_DIR/runtimes/claude/rules-core.md" "$CONFIG_DIR/rules-core.md"
  fi
  echo "[2b] Rules-enforcement hooks (settings.json)"
  ensure_rules_enforcement_hooks
}
