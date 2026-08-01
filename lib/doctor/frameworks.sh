# oh-my-agent-env: doctor domain - frameworks.sh
# Sourced by lib/doctor.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

doctor_framework_surfaces() {
  echo "[ Managed skills ]"
  # graphify is checked separately below (CLI-owned, not a oh-my-agent-env symlink).
  for sk in triangle-review codebase-scan; do
    dst="$CONFIG_DIR/skills/$sk"
    if [ -L "$dst" ] && [ -e "$dst" ]; then echo "  [OK] $sk symlink"
    elif [ -e "$dst" ]; then echo "  [WARN] $sk exists but not symlinked from oh-my-agent-env"
    else echo "  [MISS] $sk"; WARNINGS=$((WARNINGS+1)); fi
  done
  # graphify is managed by the graphify CLI itself (not oh-my-agent-env).
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

}
