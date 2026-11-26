# oh-my-env: doctor domain - local-prereqs.sh
# Sourced by lib/doctor.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

check_herdr_skill_roots() {
  local _herdr_entry _herdr_label _herdr_root _herdr_installed _herdr_skill
  for _herdr_entry in \
    "GJC|${GJC_CODING_AGENT_DIR:-$HOME/.gjc/agent}/skills" \
    "Claude|${CONFIG_DIR:-$HOME/.claude}/skills" \
    "Codex|${CODEX_DIR:-$HOME/.codex}/skills" \
    "OMO|${AGENTS_DIR:-$HOME/.agents}/skills"; do
    _herdr_label="${_herdr_entry%%|*}"
    _herdr_root="${_herdr_entry#*|}"
    for _herdr_skill in herdr-council herdr-app; do
      _herdr_installed="$_herdr_root/$_herdr_skill/SKILL.md"
      if [ -f "$_herdr_installed" ] && cmp -s "$SCRIPT_DIR/skills/$_herdr_skill/SKILL.md" "$_herdr_installed"; then
        echo "  [OK]   $_herdr_skill skill ($_herdr_label scan root)"
      else
        echo "  [MISS] $_herdr_skill skill ($_herdr_label scan root; run setup.sh sync)"
        WARNINGS=$((WARNINGS+1))
      fi
    done
  done
  # Mirrors sync_omo_herdr_extension: only expected once OMO created ~/.omo/agent.
  local _herdr_ext_src="$SCRIPT_DIR/runtimes/omo/extensions/herdr-omp-agent-state.ts"
  if [ -d "$HOME/.omo/agent" ] && [ -f "$_herdr_ext_src" ]; then
    if cmp -s "$_herdr_ext_src" "$HOME/.omo/agent/extensions/herdr-omp-agent-state.ts"; then
      echo "  [OK]   OMO herdr agent-state extension"
    else
      echo "  [MISS] OMO herdr agent-state extension (run setup.sh sync)"
      WARNINGS=$((WARNINGS+1))
    fi
  fi
}

doctor_local_prereqs() {
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
        echo "         Other users on this host can read its contents. Remove the system"
        echo "         copy: npm uninstall -g --prefix ${p%/lib/node_modules} $pkg"
        [ "$pkg" = @openai/codex ] || echo "         then re-run 'setup.sh sync' to reinstall into $USER_NPM_PREFIX"
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
        echo "         Fix: setup.sh sync (locks dirs you own), or chmod 700 $d"
        WARNINGS=$((WARNINGS+1))
      else
        echo "  [OK]   $d  mode=$_mode"
      fi
    fi
  done
  echo ""

  echo "[ CLI tools ]"
  # ocr / semantica-mcp: operator-requested 2026-08-16, installed by
  # sync_external_tools. Listed here so a machine where that install failed
  # says so instead of the /ocr plugin and semantica MCP dying quietly.
  for cmd in git node npm python3 bun claude codex gemini herdr gjc omo rtk graphify context-mode playwright ocr semantica-mcp; do
    if command -v $cmd &>/dev/null; then echo "  [OK] $cmd"
    else echo "  [MISS] $cmd"; WARNINGS=$((WARNINGS+1)); fi
  done
  echo ""
  echo "[ GJC / OMO / Herdr portable configuration ]"
  local _portable_ok=0
  python3 - "$HOME/.gjc/agent/keybindings.json" "$SCRIPT_DIR/runtimes/gjc/keybindings.json" \
              "$HOME/.omo/agent/keybindings.json" "$SCRIPT_DIR/runtimes/omo/keybindings.json" <<'PY' \
    || _portable_ok=$?
import json, sys
from pathlib import Path
for actual_name, managed_name in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    actual_path, managed_path = Path(actual_name), Path(managed_name)
    if not actual_path.exists():
        print(f"  [MISS] {actual_path}")
        raise SystemExit(1)
    try:
        actual = json.loads(actual_path.read_text())
        managed = json.loads(managed_path.read_text())
    except Exception as exc:
        print(f"  [MISS] invalid keybindings JSON: {actual_path}: {exc}")
        raise SystemExit(1)
    missing = [key for key, value in managed.items() if actual.get(key) != value]
    if missing:
        print(f"  [MISS] {actual_path} differs for: {', '.join(missing)}")
        raise SystemExit(1)
    print(f"  [OK]   {actual_path}")
PY
  if [ "$_portable_ok" -ne 0 ]; then WARNINGS=$((WARNINGS+1)); fi
  if grep -qE '^[[:space:]]*prefix[[:space:]]*=[[:space:]]*"ctrl\+v"' \
      "${HERDR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr}/config.toml" 2>/dev/null; then
    echo "  [OK]   Herdr prefix ctrl+v"
  else
    echo "  [MISS] Herdr prefix ctrl+v (run setup.sh sync)"
    WARNINGS=$((WARNINGS+1))
  fi
  for _wrapper in gjc-herdr omo-herdr; do
    if [ -x "$HOME/.local/bin/$_wrapper" ]; then
      echo "  [OK]   $_wrapper"
    else
      echo "  [MISS] $HOME/.local/bin/$_wrapper"
      WARNINGS=$((WARNINGS+1))
    fi
  done
  # Herdr skills are real files in every runtime scan root. Check each target
  # independently so a partial sync cannot look healthy through GJC alone.
  check_herdr_skill_roots
  if command -v gjc >/dev/null 2>&1; then
    local _profile _expected_profile
    _expected_profile="$(tr -d '[:space:]' < "$SCRIPT_DIR/runtimes/gjc/default-profile")"
    _profile="$(gjc config get modelProfile.default 2>/dev/null || true)"
    if [ "$_profile" = "$_expected_profile" ]; then
      echo "  [OK]   GJC default profile $_expected_profile"
    else
      echo "  [MISS] GJC default profile $_expected_profile (current: ${_profile:-unset})"
      WARNINGS=$((WARNINGS+1))
    fi
  fi

  echo ""
  echo "[ Symlinks ]"
  f="$CONFIG_DIR/commands/analyze-paper.md"
  if [ -L "$f" ] || [ -f "$f" ]; then echo "  [OK] $(basename "$f")"
  else echo "  [MISS] $f"; WARNINGS=$((WARNINGS+1)); fi

  echo ""
  echo "[ Global rules (OMS-owned) ]"
  # This repo no longer writes global rules (lib/sync/rules.sh). Leftovers of
  # the old assembly would load beside OMS's rules, so they are warnings.
  local _gc_f
  for _gc_f in "$CONFIG_DIR/CLAUDE.md" "$CODEX_DIR/AGENTS.md" "$GEMINI_DIR/GEMINI.md"; do
    if [ -f "$_gc_f" ] && grep -qF "$OMA_BLOCK_END" "$_gc_f"; then
      echo "  [STALE] $_gc_f still holds the repo rule block — run setup.sh sync"
      WARNINGS=$((WARNINGS+1))
    elif [ -L "$_gc_f" ]; then
      echo "  [OK]   $(basename "$_gc_f") -> $(readlink "$_gc_f")"
    else
      echo "  [OK]   $(basename "$_gc_f"): no repo rule block"
    fi
  done
  if [ -L "$CODEX_DIR/instructions.md" ] && case "$(readlink "$CODEX_DIR/instructions.md")" in "$SCRIPT_DIR"/*) true ;; *) false ;; esac; then
    echo "  [STALE] $CODEX_DIR/instructions.md still links into this repo — run setup.sh sync"
    WARNINGS=$((WARNINGS+1))
  fi

  echo ""

}
