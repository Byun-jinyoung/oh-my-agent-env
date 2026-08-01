# oh-my-agent-env: cmd_doctor loader (sourced by setup.sh)
# Not standalone — relies on globals defined in setup.sh and helpers from
# lib/common.sh (must be sourced first).
#
# The diagnostic implementation lives under lib/doctor/*.sh so doctor can
# evolve by domain without changing setup.sh dispatch.
# shellcheck shell=bash   # sourced fragment: no shebang by design

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/doctor/local-prereqs.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/doctor/claude.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/doctor/codex-integrity.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/doctor/lazycodex.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/doctor/agent-mcp.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/doctor/frameworks.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/doctor/main.sh"
