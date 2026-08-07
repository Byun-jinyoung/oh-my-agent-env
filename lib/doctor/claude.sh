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
  echo "[ Machine snapshot ]"
  # Verify the EFFECT, not sync's claim. Four surfaces instruct the agent to read
  # this file — templates/project-ml-AGENTS.md:15,:56,
  # skills/multi-agent-review/SKILL.md:27, and the path apply-project-template.sh
  # stamps into every scaffolded PROJECT.md — and it was absent on this machine
  # while all four pointed at it. A pointer to a file that never existed reads to
  # the agent as "no compute constraints", which is not the same as "unknown".
  # Checked at the path the surfaces cite, not at $SCRIPT_DIR/local — those are
  # the same directory here and would diverge on any other checkout.
  if [ -f "$HOME/.oh-my-agent-env/local/machine.md" ]; then
    echo "  [OK] ~/.oh-my-agent-env/local/machine.md"
  else
    echo "  [MISS] ~/.oh-my-agent-env/local/machine.md — 4 agent-facing surfaces cite it; run 'setup.sh sync'"
    WARNINGS=$((WARNINGS+1))
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
  echo "[ Project hooks (.claude/settings.json) ]"
  # The section above validates ~/.claude/settings.json. A project can register
  # its own hooks in .claude/settings.json, and nothing looked at that file —
  # which is how a hook sat dead for its whole life without anyone noticing.
  #
  # The case that prompted this: a PreToolUse hook fires on every rg/grep and
  # tells the model to consult the graphify graph first, but it is gated on
  # `[ -f graphify-out/graph.json ]` and that file does not exist in any
  # checkout here. The hook runs thousands of times and exits silently every
  # time. Registered and firing are not the same thing, and only one of them
  # was being checked.
  if ! command -v python3 &>/dev/null; then
    echo "  [SKIP] python3 missing"
  elif ! python3 - "$SCRIPT_DIR" <<'PYEOF'
import json, os, re, sys

root = sys.argv[1]
path = os.path.join(root, ".claude", "settings.json")
warn = 0

if not os.path.isfile(path):
    print("  [SKIP] no project .claude/settings.json")
    sys.exit(0)
try:
    data = json.loads(open(path).read())
except (OSError, ValueError) as exc:
    print(f"  [WARN] project settings.json unreadable ({exc}) — hooks not checked")
    sys.exit(1)

hooks = [
    (event, h.get("command", ""))
    for event, arr in (data.get("hooks") or {}).items() if isinstance(arr, list)
    for g in arr if isinstance(g, dict)
    for h in g.get("hooks", []) if isinstance(h, dict)
]
if not hooks:
    print("  [SKIP] project settings.json registers no hooks")
    sys.exit(0)

# Only file-existence gates. A hook can be conditional in ways this cannot read
# (exit codes, greps, env); those are counted as unchecked rather than passed.
GATE = re.compile(r'\[\s+-([fde])\s+"?([^"\]\s]+)"?\s+\]')
gated = unchecked = 0

for event, cmd in hooks:
    conds = GATE.findall(cmd)
    if not conds:
        unchecked += 1
        continue
    for kind, raw in conds:
        gated += 1
        # $CLAUDE_PROJECT_DIR is the one variable the runtime guarantees here.
        p = raw.replace("$CLAUDE_PROJECT_DIR", root).replace("${CLAUDE_PROJECT_DIR}", root)
        if "$" in p:
            print(f"  [WARN] {event}: gate on '{raw}' has an unexpanded variable — not checked")
            warn += 1
            continue
        full = p if os.path.isabs(p) else os.path.join(root, p)
        ok = os.path.isfile(full) if kind == "f" else (
            os.path.isdir(full) if kind == "d" else os.path.exists(full))
        if ok:
            print(f"  [OK]   {event}: gate '{p}' is satisfied")
        else:
            print(f"  [DEAD] {event}: gated on '{p}', which does not exist —")
            print("         the hook runs on every matching call and exits silently.")
            warn += 1

if unchecked:
    print(f"  [NOTE] {unchecked} hook(s) carry no file gate this check can read")
sys.exit(1 if warn else 0)
PYEOF
  then
    WARNINGS=$((WARNINGS+1))
  fi

  echo ""
  echo "[ Rule mirror (SSOT vs the tree the runtime actually reads) ]"
  # An oma-managed project carries the same rules twice, and only one copy
  # reaches the model. `.claude/rules/*.md` is loaded by the runtime — observed:
  # their bodies arrive in context while nothing in this repo injects them, no
  # @import in CLAUDE.md and no hook. `.agents/rules/*.md` is the SSOT this
  # project is forbidden to edit, and it is what CLAUDE.md's rules table tells
  # the model to go read. Both trees are written by the oma package, neither by
  # sync, and until now nothing compared them: they agree today by luck.
  #
  # Frontmatter is a deliberate schema translation, not drift — the SSOT carries
  # `globs`/`alwaysApply`, the mirror carries `paths`. Comparing bytes would fail
  # on every file on day one. What has to agree is the rule body and the scope
  # those two keys express, so that is what this compares.
  if ! command -v python3 &>/dev/null; then
    echo "  [SKIP] python3 missing"
  elif ! python3 - "$SCRIPT_DIR" <<'PYEOF'
import sys
from pathlib import Path

root = Path(sys.argv[1])
ssot, mirror = root / ".agents" / "rules", root / ".claude" / "rules"
warn = 0

if not ssot.is_dir():
    print("  [SKIP] no .agents/rules (not an oma-managed project)")
    sys.exit(0)
if not mirror.is_dir():
    print("  [MISS] .agents/rules exists but .claude/rules does not —")
    print("         the runtime loads no project rules at all. Re-run the oma sync.")
    sys.exit(1)


def split(path):
    """Frontmatter dict and body. Hand-rolled on purpose: PyYAML is not a
    dependency here, and the schema in play is one flat key: value per line."""
    try:
        text = path.read_text()
    except OSError as exc:
        return None, None, str(exc)
    lines = text.splitlines()
    fm, start = {}, 0
    if lines and lines[0].strip() == "---":
        for i, line in enumerate(lines[1:], 1):
            if line.strip() == "---":
                start = i + 1
                break
            key, sep, val = line.partition(":")
            if sep and not key.startswith((" ", "\t")):
                fm[key.strip()] = val.strip().strip("\"'")
    # Blank runs and trailing spaces are reflow, not meaning. Dropping them
    # cannot hide a changed rule — only a rewrapped one.
    body = [ln.rstrip() for ln in lines[start:] if ln.strip()]
    return fm, body, None


names = sorted(p.name for p in ssot.glob("*.md"))
if not names:
    print("  [WARN] .agents/rules holds no .md files — nothing to compare")
    sys.exit(1)

for name in names:
    a_fm, a_body, err = split(ssot / name)
    if err:
        print(f"  [WARN] {name}: SSOT unreadable ({err}) — comparison not run")
        warn += 1
        continue
    target = mirror / name
    if not target.is_file():
        print(f"  [MISS] {name}: in .agents/rules with no mirror —")
        print("         the runtime never sees this rule. Re-run the oma sync.")
        warn += 1
        continue
    b_fm, b_body, err = split(target)
    if err:
        print(f"  [WARN] {name}: mirror unreadable ({err}) — comparison not run")
        warn += 1
        continue
    if a_body != b_body:
        print(f"  [MISS] {name}: rule body differs between the SSOT and the tree")
        print("         the runtime reads. The model is following the mirror.")
        warn += 1
        continue
    # `globs` is the SSOT's scope key, `paths` the mirror's. Absent on both
    # sides means "on request", which is agreement, not a gap.
    if a_fm.get("globs", "") != b_fm.get("paths", ""):
        print(f"  [MISS] {name}: scope differs — SSOT globs={a_fm.get('globs', '') or '<none>'!r}"
              f" vs mirror paths={b_fm.get('paths', '') or '<none>'!r}")
        warn += 1

orphans = sorted(p.name for p in mirror.glob("*.md") if p.name not in names)
for name in orphans:
    print(f"  [WARN] {name}: in .claude/rules with no SSOT behind it —")
    print("         the model is being given a rule this project does not own.")
    warn += 1

if not warn:
    print(f"  [OK]   {len(names)} rules mirrored with matching bodies and scopes")
sys.exit(1 if warn else 0)
PYEOF
  then
    WARNINGS=$((WARNINGS+1))
  fi

  echo ""

}
