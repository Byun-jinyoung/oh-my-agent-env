# oh-my-agent-env: doctor domain - agent-mcp.sh
# Sourced by lib/doctor.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

doctor_agent_mcp_surfaces() {
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

}
