# oh-my-agent-env: doctor domain - lazycodex.sh
# Sourced by lib/doctor.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

doctor_lazycodex() {
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

}
