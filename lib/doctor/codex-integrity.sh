# oh-my-agent-env: doctor domain - codex-integrity.sh
# Sourced by lib/doctor.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

doctor_codex_integrity() {
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
  # codex CLI — exactly one install, from the official standalone installer
  local _codex_dups _codex_p _codex_cmd
  if codex_standalone; then
    echo "  [OK] codex CLI standalone ($HOME/.local/bin/codex → $(readlink -f "$HOME/.local/bin/codex"))"
  elif [ -e "$HOME/.local/bin/codex" ] || command -v codex &>/dev/null; then
    echo "  [WARN] codex CLI not from the official installer — run 'setup.sh sync' or: $CODEX_INSTALL_CMD"
    WARNINGS=$((WARNINGS+1))
  else
    echo "  [FAIL] codex CLI missing — run 'setup.sh sync' or: $CODEX_INSTALL_CMD"
    WARNINGS=$((WARNINGS+1))
  fi
  _codex_dups="$(codex_duplicates)"
  if [ -n "$_codex_dups" ]; then
    echo "  [WARN] other codex installs (PATH order decides which runs) — remove:"
    while IFS="$(printf '\t')" read -r _codex_p _codex_cmd; do
      echo "          • $_codex_p  →  $_codex_cmd"
    done <<EOF
$_codex_dups
EOF
    command -v codex &>/dev/null && echo "          PATH winner: $(command -v codex)"
    WARNINGS=$((WARNINGS+1))
  fi

  echo ""

}
