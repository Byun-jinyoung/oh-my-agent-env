# oh-my-agent-env: sync domain - rules.sh
# Sourced by lib/sync.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

# [3][3b][4][4b] Codex instructions, Gemini dir, global rule assembly
sync_agent_rules() {
  # Codex
  echo "[3] Codex"
  mkdir -p "$CODEX_DIR"
  [ -f "$SCRIPT_DIR/runtimes/codex/instructions.md" ] && \
    make_link "$SCRIPT_DIR/runtimes/codex/instructions.md" "$CODEX_DIR/instructions.md"
  echo "[3b] Codex feature flags"
  ensure_codex_multi_agent

  # Gemini
  echo "[4] Gemini"
  mkdir -p "$GEMINI_DIR"

  # Global rule files (Layer A + Layer B) — Claude, Codex, Gemini
  echo "[4b] Global rule assembly"
  assemble_global_rules
}
