# oh-my-agent-env: sync domain - skills.sh
# Sourced by lib/sync.sh; not standalone.

# [5][6] Shared skills (registry.yaml) + statusline
sync_skills_statusline() {
  # Shared skills (from registry.yaml)
  echo "[5] Shared skills"
  if [ -f "$SCRIPT_DIR/skills/registry.yaml" ] && command -v python3 &>/dev/null; then
    python3 << PYEOF
import sys, os
try:
    import yaml
except ImportError:
    yaml = None

registry_path = "$SCRIPT_DIR/skills/registry.yaml"
if yaml:
    with open(registry_path) as f:
        reg = yaml.safe_load(f)
else:
    print("    [WARN] PyYAML missing. Using minimal registry parser.")
    reg = {}
    current = None
    with open(registry_path) as f:
        for raw in f:
            line = raw.split("#", 1)[0].rstrip()
            if not line:
                continue
            if not line.startswith(" ") and line.endswith(":"):
                current = line[:-1]
                reg[current] = {}
            elif current and line.strip().startswith("path:"):
                reg[current]["path"] = line.split(":", 1)[1].strip()
            elif current and line.strip().startswith("runtimes:"):
                value = line.split(":", 1)[1].strip()
                reg[current]["runtimes"] = [x.strip() for x in value.strip("[]").split(",") if x.strip()]
dirs = {"claude": "$CONFIG_DIR/skills", "codex": "$CODEX_DIR/skills", "agents": "$AGENTS_DIR/skills", "antigravity": "$GEMINI_DIR/skills"}
for name, info in reg.items():
    for rt in info.get("runtimes", []):
        if rt not in dirs: continue
        src = os.path.join("$SCRIPT_DIR", info["path"], rt)
        if not os.path.exists(src): src = os.path.join("$SCRIPT_DIR", info["path"])
        dst = os.path.join(dirs[rt], name)
        os.makedirs(dirs[rt], exist_ok=True)
        if os.path.islink(dst): os.remove(dst)
        elif os.path.exists(dst): os.rename(dst, dst+".bak")
        os.symlink(src, dst)
        print(f"    [LINK] {rt}/{name} → {src}")

# Prune stale oh-my-agent-env symlinks no longer in the registry, so that
# dropping a runtime from registry.yaml self-cleans on every machine.
# Only oh-my-agent-env-managed symlinks are removed; real dirs / foreign
# links are left untouched.
skills_root = os.path.realpath(os.path.join("$SCRIPT_DIR", "skills"))
desired = {(rt, name) for name, info in reg.items()
           for rt in info.get("runtimes", []) if rt in dirs}
for rt, d in dirs.items():
    if not os.path.isdir(d): continue
    for entry in os.listdir(d):
        p = os.path.join(d, entry)
        if not os.path.islink(p): continue
        if os.path.realpath(p).startswith(skills_root) and (rt, entry) not in desired:
            os.remove(p)
            print(f"    [PRUNE] {rt}/{entry} (stale)")
PYEOF
  fi

  # [5b] Lab tools on PATH. These run inside research repos, so they need a
  # name rather than an absolute path into this checkout — an agent that has to
  # spell out ~/.oh-my-agent-env/scripts/lab/... will simply not use them.
  echo "[5b] Lab experiment tools"
  if [ -f "$SCRIPT_DIR/scripts/oma-lab" ]; then
    mkdir -p "$HOME/.local/bin"
    make_link "$SCRIPT_DIR/scripts/oma-lab" "$HOME/.local/bin/oma-lab"
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) log_and_print "    [WARN] \$HOME/.local/bin is not on PATH — 'oma-lab' will not resolve" ;;
    esac
  fi

  # Statusline
  echo "[6] Statusline"
  if [ -f "$SCRIPT_DIR/ui/statusline/my-statusline.mjs" ]; then
    mkdir -p "$CONFIG_DIR/hud"
    make_link "$SCRIPT_DIR/ui/statusline/my-statusline.mjs" "$CONFIG_DIR/hud/my-statusline.mjs"
    # Register the global statusLine in settings.json. Previously sync only
    # created the symlink and the statusLine key was a manual step — so on a
    # fresh `clone → sync` machine the statusline never applied. Always point
    # it at our script (policy: ours wins) so it's reproducible everywhere.
    local _sl_cmd
    if [ "$CONFIG_DIR" = "$HOME/.claude" ]; then
      _sl_cmd='node $HOME/.claude/hud/my-statusline.mjs'
    else
      _sl_cmd="node $CONFIG_DIR/hud/my-statusline.mjs"
    fi
    python3 - "$CONFIG_DIR/settings.json" "$_sl_cmd" << 'PYEOF'
import json, os, sys, tempfile
p, cmd = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(p)) if os.path.exists(p) else {}
except Exception as e:
    print(f"    [WARN] settings.json unreadable ({e}); statusLine not set"); sys.exit(0)
want = {"type": "command", "command": cmd}
if d.get("statusLine") == want:
    print("    [OK] statusLine already registered"); sys.exit(0)
d["statusLine"] = want
os.makedirs(os.path.dirname(p), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False); f.write("\n")
os.replace(tmp, p)
print(f"    [OK] statusLine registered -> {cmd}")
PYEOF
  fi
}
