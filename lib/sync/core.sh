# oh-my-agent-env: sync domain - core.sh
# Sourced by lib/sync.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

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

# [2c] Machine snapshot. Three agent-facing surfaces tell the agent to read
# ~/.oh-my-agent-env/local/machine.md when compute, GPU/CUDA or Slurm matter —
# templates/project-ml-AGENTS.md:15 and :56, skills/multi-agent-review/SKILL.md:27,
# and apply-project-template.sh:139 stamps the path into every scaffolded
# PROJECT.md. The writer existed and local/ is gitignored on purpose ("generated
# per machine, never synced"), but nothing ever ran it: the file was absent here
# while all four surfaces pointed at it.
#
# Written only when missing. Regenerating on every sync would re-probe hardware
# that has not changed; `write-machine-snapshot.sh` is the way to refresh it after
# a hardware or driver change, which is what its own header already says.
#
# The path is the writer's own default and is NOT overridden here. All four
# surfaces hardcode ~/.oh-my-agent-env/local/machine.md, so pinning it to
# $SCRIPT_DIR/local would manage a different file than the agent is told to read
# on any machine where the harness is checked out somewhere else. They happen to
# be the same path here, which is exactly how that would have gone unnoticed.
sync_machine_snapshot() {
  local writer="$SCRIPT_DIR/scripts/write-machine-snapshot.sh"
  local out="$HOME/.oh-my-agent-env/local/machine.md"
  echo "[2c] Machine snapshot"
  if [ ! -f "$writer" ]; then
    log_and_print "  [FAIL] missing $writer"
    ERRORS=$((ERRORS+1))
    return
  fi
  if [ -f "$out" ]; then
    log_and_print "  [SKIP] $out exists — refresh with scripts/write-machine-snapshot.sh"
    return
  fi
  if bash "$writer" >/dev/null 2>&1; then
    log_and_print "  [OK] wrote $out"
  else
    log_and_print "  [FAIL] could not write $out"
    ERRORS=$((ERRORS+1))
  fi
}
