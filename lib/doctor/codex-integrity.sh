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

}
