# oh-my-agent-env: doctor domain - claude.sh
# Sourced by lib/doctor.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

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
    # Once, not five times: `claude mcp list` shells out to every registered
    # server, and this ran it per name plus once more for the stale check.
    _mcp_list="$(maybe_timeout 90 claude mcp list </dev/null 2>/dev/null || true)"
    # `[MISS] serena` on its own points at the wrong repair. Found live: serena
    # was registered as bare `serena`, which is not on PATH, so it could never
    # start — and `setup.sh sync` cannot heal it, because add_mcp treats a name
    # appearing in the list as OK and compares only env, never the command. The
    # reason comes from the registry file, so it costs no extra handshake.
    _mcp_why=""
    if command -v python3 &>/dev/null; then
      _mcp_why="$(python3 - "$HOME/.claude.json" "$CONFIG_DIR/.claude.json" 2>/dev/null << 'PYEOF'
import json, os, shutil, sys

path = next((p for p in sys.argv[1:] if os.path.isfile(p)), None)
if path is None:
    raise SystemExit(0)
try:
    servers = json.load(open(path)).get("mcpServers") or {}
except Exception:
    raise SystemExit(0)
for name, cfg in servers.items():
    if not isinstance(cfg, dict):
        continue
    cmd = cfg.get("command")
    if cfg.get("type") in ("http", "sse") or not cmd:
        continue   # remote transport: being down is an auth or network answer
    envp = (cfg.get("env") or {}).get("PATH")
    if os.path.isabs(cmd):
        ok = os.path.isfile(cmd) and os.access(cmd, os.X_OK)
    else:
        ok = shutil.which(cmd, path=envp or os.environ.get("PATH", "")) is not None
    if not ok:
        where = "its baked PATH" if envp else "the inherited PATH"
        print("%s\t'%s' is not on %s, so the server cannot start" % (name, cmd, where))
PYEOF
)"
    fi
    for m in codex-mcp antigravity-mcp serena supermemory; do
      if printf '%s\n' "$_mcp_list" | grep -qE "$m.*(Connected|Needs authentication)"; then echo "  [OK] $m"
      else
        _why="$(printf '%s\n' "$_mcp_why" | sed -n "s/^$m	//p" | head -1)"
        echo "  [MISS] $m${_why:+ — $_why}"
        WARNINGS=$((WARNINGS+1))
      fi
    done
    # Detect stale gemini-mcp entry (fork no longer provides it)
    if printf '%s\n' "$_mcp_list" | grep -qE '^gemini-mcp\b|^gemini-mcp\s'; then
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
