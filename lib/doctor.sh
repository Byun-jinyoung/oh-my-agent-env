# oh-my-agent-env: cmd_doctor (sourced by setup.sh)
# Not standalone — relies on globals defined in setup.sh and helpers from
# lib/common.sh (must be sourced first).

cmd_doctor() {
  echo "=== oh-my-agent-env doctor ==="

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
  if [ -x "$HOME/.local/bin/omo" ]; then
    echo "  [OK] omo ($HOME/.local/bin/omo)"
  elif command -v omo &>/dev/null; then
    echo "  [OK] omo ($(command -v omo))"
  else
    echo "  [MISS] omo (installed by LazyCodex; run setup.sh sync)"
    WARNINGS=$((WARNINGS+1))
  fi

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
  echo "[ LazyCodex (Codex plugin) ]"
  if verify_lazycodex_codex_plugin; then
    _lazycodex_root="$(find "$CODEX_DIR/plugins/cache/sisyphuslabs/omo" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)"
    _lazycodex_version="$(basename "$_lazycodex_root" 2>/dev/null)"
    echo "  [OK] omo@sisyphuslabs installed, enabled${_lazycodex_version:+ ($_lazycodex_version)}"
    echo "       root: ${_lazycodex_root:-?}"
  else
    echo "  [MISS] LazyCodex Codex plugin (expected omo@sisyphuslabs) — run setup.sh sync"
    WARNINGS=$((WARNINGS+1))
  fi

  echo ""
  echo "[ MCP servers (Codex/Antigravity for triangle-review) ]"
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
  # Antigravity MCP check — primary location is ~/.gemini/config/mcp_config.json
  # (read by agy CLI and Antigravity IDE). The pre-2026-05-19 top-level
  # ~/.gemini/settings.json is checked too as a transition guard: stale
  # entries there are reported as WARN so users know to migrate.
  if command -v python3 &>/dev/null; then
    python3 - "$GEMINI_DIR/config/mcp_config.json" "$GEMINI_DIR/settings.json" << 'PYEOF'
import json, sys
from pathlib import Path

shared = Path(sys.argv[1])
legacy = Path(sys.argv[2])

shared_servers = {}
if shared.exists() and shared.stat().st_size > 0:
    try:
        shared_servers = json.loads(shared.read_text()).get("mcpServers", {})
    except Exception as e:
        print(f"  [WARN] {shared} unparseable: {e}")

for name in ("serena", "code-review-graph"):
    if name in shared_servers: print(f"  [OK] antigravity {name}")
    else: print(f"  [MISS] antigravity {name} (expected in config/mcp_config.json — run setup.sh sync)")

# Legacy location: warn if old gemini-cli settings.json still has mcpServers
if legacy.exists():
    try:
        legacy_servers = json.loads(legacy.read_text()).get("mcpServers", {})
        if legacy_servers:
            stale = ", ".join(sorted(legacy_servers.keys()))
            print(f"  [WARN] stale mcpServers in {legacy.name}: {stale} — agy ignores these. Run setup.sh sync to migrate.")
    except Exception:
        pass
PYEOF
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
  # Runtime dependency resolution: a stdio handshake only proves the MCP server
  # binary launched — NOT that the tools it shells out to (e.g. antigravity-mcp
  # -> `agy`) are reachable under the PATH codex bakes into that server. This
  # check resolves each managed server's command + downstream deps UNDER its own
  # baked env.PATH, catching the "installed but non-functional" false-OK class.
  if command -v python3 &>/dev/null; then
    # Use a temp-file redirect (NOT $(... << heredoc ...)) — a heredoc body with
    # single quotes nested inside command substitution confuses bash's parser.
    _rtf="$(mktemp)"
    python3 - "$CODEX_DIR/config.toml" > "$_rtf" 2>&1 << 'PYEOF'
import sys, os, shutil
cfg = sys.argv[1]
try:
    import tomllib
except ImportError:
    print("  [SKIP] runtime dep check (python<3.11, no tomllib)"); print("__WARN__0"); sys.exit(0)
try:
    d = tomllib.load(open(cfg, "rb"))
except Exception as e:
    print(f"  [WARN] runtime dep check: cannot read config.toml ({e})"); print("__WARN__1"); sys.exit(0)
m = d.get("mcp_servers", {})
# server -> downstream executables it also needs at runtime
checks = {"context-mode": [], "serena": [], "code-review-graph": [], "antigravity-mcp": ["agy"]}
warn = 0
for name, deps in checks.items():
    s = m.get(name)
    if not s:
        continue
    cmd = s.get("command", "") or ""
    envp = (s.get("env") or {}).get("PATH")
    # No baked env PATH => the server is NOT hardened; it relies on whatever PATH
    # codex inherits at spawn time. Resolving in doctor's own (login) shell would
    # be a false-OK, so flag it outright rather than guessing.
    if not envp:
        print(f"  [WARN] codex {name}: no baked env PATH — relies on codex inherited PATH (run setup.sh sync to harden)")
        warn += 1
        continue
    base = os.path.basename(cmd) if cmd else name
    for t in [base] + deps:
        if t == base and os.path.isabs(cmd):
            ok = os.path.isfile(cmd) and os.access(cmd, os.X_OK)
        else:
            ok = shutil.which(t, path=envp) is not None
        print(f"  [{'OK' if ok else 'WARN'}] codex {name}: '{t}' resolves under baked PATH")
        warn += 0 if ok else 1
print(f"__WARN__{warn}")
PYEOF
    grep -v '^__WARN__' "$_rtf"
    _rtw="$(sed -n 's/^__WARN__//p' "$_rtf" | tail -1)"
    [ -n "$_rtw" ] && [ "$_rtw" -gt 0 ] 2>/dev/null && WARNINGS=$((WARNINGS+_rtw))
    rm -f "$_rtf"
  fi

  echo ""
  echo "[ Managed skills ]"
  # graphify is checked separately below (CLI-owned, not a oh-my-agent-env symlink).
  for sk in triangle-review codebase-scan; do
    src="$SCRIPT_DIR/skills/$sk"
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

  echo ""
  [ $WARNINGS -gt 0 ] && echo "  $WARNINGS item(s) missing." || echo "  All checks passed."
}
