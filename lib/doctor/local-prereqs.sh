# oh-my-agent-env: doctor domain - local-prereqs.sh
# Sourced by lib/doctor.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

check_herdr_skill_roots() {
  local _herdr_entry _herdr_label _herdr_root _herdr_installed
  local _herdr_council_src="$SCRIPT_DIR/skills/herdr-council/SKILL.md"
  for _herdr_entry in \
    "GJC|${GJC_CODING_AGENT_DIR:-$HOME/.gjc/agent}/skills" \
    "Claude|${CONFIG_DIR:-$HOME/.claude}/skills" \
    "Codex|${CODEX_DIR:-$HOME/.codex}/skills" \
    "OMO|${AGENTS_DIR:-$HOME/.agents}/skills"; do
    _herdr_label="${_herdr_entry%%|*}"
    _herdr_root="${_herdr_entry#*|}"
    _herdr_installed="$_herdr_root/herdr-council/SKILL.md"
    if [ -f "$_herdr_installed" ] && cmp -s "$_herdr_council_src" "$_herdr_installed"; then
      echo "  [OK]   herdr-council skill ($_herdr_label scan root)"
    else
      echo "  [MISS] herdr-council skill ($_herdr_label scan root; run setup.sh sync)"
      WARNINGS=$((WARNINGS+1))
    fi
    if command -v herdr >/dev/null 2>&1; then
      if [ -f "$_herdr_root/herdr/SKILL.md" ]; then
        echo "  [OK]   herdr skill ($_herdr_label scan root)"
      else
        echo "  [MISS] herdr skill ($_herdr_label scan root; run setup.sh sync)"
        WARNINGS=$((WARNINGS+1))
      fi
    fi
  done
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
  # ocr / semantica-mcp: operator-requested 2026-08-16, installed by
  # sync_external_tools. Listed here so a machine where that install failed
  # says so instead of the /ocr plugin and semantica MCP dying quietly.
  for cmd in git node npm python3 bun claude codex gemini herdr gjc omo rtk graphify context-mode playwright ocr semantica-mcp; do
    if command -v $cmd &>/dev/null; then echo "  [OK] $cmd"
    else echo "  [MISS] $cmd"; WARNINGS=$((WARNINGS+1)); fi
  done
  # LazyCodex CLI: 5.x links omo-agent-toolkit; 4.x linked omo. Plain `omo`
  # on PATH is now the standalone omo-ai (senpi) edition, not LazyCodex.
  if [ -x "$HOME/.local/bin/omo-agent-toolkit" ]; then
    echo "  [OK] omo-agent-toolkit ($HOME/.local/bin/omo-agent-toolkit)"
  elif [ -x "$HOME/.local/bin/omo" ]; then
    echo "  [OK] omo ($HOME/.local/bin/omo — LazyCodex 4.x wrapper)"
  else
    echo "  [MISS] omo-agent-toolkit (installed by LazyCodex; run setup.sh sync)"
    WARNINGS=$((WARNINGS+1))
  fi

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
  for f in "$CONFIG_DIR/commands/analyze-paper.md" \
    "$CODEX_DIR/instructions.md" "$GEMINI_DIR/GEMINI.md"; do
    if [ -L "$f" ] || [ -f "$f" ]; then echo "  [OK] $(basename "$f")"
    else echo "  [MISS] $f"; WARNINGS=$((WARNINGS+1)); fi
  done

  echo ""
  echo "[ Global instruction contract ]"
  # Exactly one resident contract per supported runtime. User text outside the
  # managed block is allowed; a missing, duplicate or stale block is not.
  # Generate the expected body without calling assemble_global_rules, because
  # doctor is diagnostic and must never repair the live files it inspects.
  local _gc_cli _gc_target _gc_tools _gc_expected _gc_rc
  for _gc_cli in claude codex antigravity; do
    case "$_gc_cli" in
      claude)
        _gc_target="$CONFIG_DIR/CLAUDE.md"
        _gc_tools="$SCRIPT_DIR/runtimes/claude/tools.md"
        ;;
      codex)
        _gc_target="$CODEX_DIR/AGENTS.md"
        _gc_tools="$SCRIPT_DIR/runtimes/codex/tools.md"
        ;;
      antigravity)
        _gc_target="$GEMINI_DIR/GEMINI.md"
        _gc_tools="$SCRIPT_DIR/runtimes/antigravity/tools.md"
        ;;
    esac
    _gc_expected="$(mktemp)"
    { cat "$SCRIPT_DIR"/rules/*.md; emit_rule_index; printf '\n'; cat "$_gc_tools"; } > "$_gc_expected"
    python3 - "$_gc_target" "$_gc_expected" "$OMA_BLOCK_BEGIN" "$OMA_BLOCK_END" <<'PYEOF'
import sys
from pathlib import Path

target, expected = Path(sys.argv[1]), Path(sys.argv[2])
begin, end = sys.argv[3], sys.argv[4]
if not target.is_file():
    raise SystemExit(1)
text = target.read_text(encoding="utf-8")
if text.count(begin) != 1 or text.count(end) != 1:
    raise SystemExit(1)
body = text.split(begin, 1)[1].split(end, 1)[0].strip()
want = expected.read_text(encoding="utf-8").strip()
if body != want:
    raise SystemExit(1)
PYEOF
    _gc_rc=$?
    rm -f "$_gc_expected"
    if [ "$_gc_rc" -eq 0 ]; then
      echo "  [OK]   $_gc_cli: exactly one current managed contract"
    else
      echo "  [STALE] $_gc_cli: global contract missing, duplicate, or out of date — run setup.sh sync"
      WARNINGS=$((WARNINGS+1))
    fi
  done

  echo ""

}
