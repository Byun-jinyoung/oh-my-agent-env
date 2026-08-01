# oh-my-agent-env: doctor domain - claude.sh
# Sourced by lib/doctor.sh; not standalone.

doctor_claude_surfaces() {
  echo "[ Plugins ]"
  if command -v claude &>/dev/null; then
    for p in "octo@nyldn" "claude-mem@thedotmack" "ouroboros@ouroboros" "document-skills@anthropic" "context-mode@context-mode" "codex@openai-codex"; do
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
  echo "[ Rules-enforcement hooks ]"
  # Verify the EFFECT, not sync's claim: read the settings.json Claude will
  # actually load and confirm every manifest hook is present and points at a
  # file that exists. sync treats hook wiring as non-fatal, so a failure there
  # is otherwise silent — which is exactly how three hooks once shipped as dead
  # code on every machine that had not been hand-edited.
  if ! command -v python3 &>/dev/null; then
    echo "  [SKIP] python3 missing"
  elif ! python3 - "$CONFIG_DIR" "$SCRIPT_DIR/runtimes/claude/hooks" <<'PYEOF'
import json, sys
from pathlib import Path

config_dir, repo_hooks = Path(sys.argv[1]), Path(sys.argv[2])
manifest = repo_hooks / "manifest.json"
settings = config_dir / "settings.json"
warn = 0

try:
    want = json.loads(manifest.read_text())["hooks"]
except (OSError, ValueError, KeyError) as exc:
    print(f"  [MISS] hook manifest unreadable: {exc}")
    sys.exit(1)

try:
    data = json.loads(settings.read_text())
except (OSError, ValueError) as exc:
    print(f"  [MISS] settings.json unreadable: {exc}")
    sys.exit(1)

registered = [
    (event, x.get("command", ""))
    for event, arr in (data.get("hooks") or {}).items() if isinstance(arr, list)
    for g in arr if isinstance(g, dict)
    for x in g.get("hooks", []) if isinstance(x, dict)
]

for h in want:
    script, event = h["script"], h["event"]
    hits = [c for ev, c in registered if ev == event and script in c]
    if not hits:
        print(f"  [MISS] {event}:{script} not registered — run 'setup.sh sync'")
        warn += 1
    elif len(hits) > 1:
        print(f"  [DUP]  {event}:{script} registered {len(hits)}x")
        warn += 1
    elif not (config_dir / "hooks" / script).exists():
        print(f"  [DEAD] {event}:{script} registered but {config_dir}/hooks/{script} is missing")
        warn += 1
    else:
        print(f"  [OK]   {event}:{script}")

sys.exit(1 if warn else 0)
PYEOF
  then
    WARNINGS=$((WARNINGS+1))
  fi

  echo ""

}
