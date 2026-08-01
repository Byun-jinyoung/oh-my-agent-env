# oh-my-agent-env: doctor diagnostics orchestrator
# Sourced by lib/doctor.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

cmd_doctor() {
  echo "=== oh-my-agent-env doctor ==="

  # Establish the same user-owned prefix the sync uses, so diagnostics and
  # repair behavior use the same install vocabulary.
  ensure_user_npm_prefix

  doctor_local_prereqs
  doctor_claude_surfaces
  doctor_codex_integrity
  doctor_lazycodex
  doctor_agent_mcp_surfaces
  doctor_framework_surfaces

  echo ""
  [ $WARNINGS -gt 0 ] && echo "  $WARNINGS item(s) missing." || echo "  All checks passed."
}
