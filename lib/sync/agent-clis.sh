# oh-my-env: GJC / OMO / Herdr install and portable configuration
# Sourced by lib/sync.sh; not standalone.
# shellcheck shell=bash

merge_agent_keybindings() {
  local target="$1" managed="$2"
  mkdir -p "$(dirname "$target")"
  python3 - "$target" "$managed" <<'PY'
import json, os, shutil, sys, tempfile
from pathlib import Path

target, managed = map(Path, sys.argv[1:3])
try:
    desired = json.loads(managed.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"[FAIL] invalid managed keybindings {managed}: {exc}")
    sys.exit(2)

if target.exists():
    try:
        current = json.loads(target.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[WARN] invalid JSON left unchanged: {target}: {exc}")
        sys.exit(3)
    if not isinstance(current, dict):
        print(f"[WARN] non-object JSON left unchanged: {target}")
        sys.exit(3)
else:
    current = {}

merged = dict(current)
merged.update(desired)
rendered = json.dumps(merged, ensure_ascii=False, indent=2) + "\n"
old = target.read_text(encoding="utf-8") if target.exists() else None
if old == rendered:
    print(f"[OK] {target} already current")
    sys.exit(0)
if target.exists():
    shutil.copy2(target, target.with_name(target.name + ".bak.oh-my-agent-env"))
fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"[OK] merged managed keybindings into {target}")
PY
}

merge_herdr_config() {
  local target="$1" managed="$2"
  mkdir -p "$(dirname "$target")"
  python3 - "$target" "$managed" <<'PY'
import os, re, shutil, sys, tempfile
from pathlib import Path

target, managed = map(Path, sys.argv[1:3])
template = managed.read_text(encoding="utf-8")
match = re.search(r'(?m)^prefix\s*=\s*("[^"]+")\s*$', template)
if not match:
    print(f"[FAIL] no valid prefix in {managed}")
    sys.exit(2)
prefix = f"prefix = {match.group(1)}"
old = target.read_text(encoding="utf-8") if target.exists() else ""
lines = old.splitlines()
headers = [i for i, line in enumerate(lines) if line.strip() == "[keys]"]
if len(headers) > 1:
    print(f"[WARN] duplicate [keys] sections left unchanged: {target}")
    sys.exit(3)
if headers:
    start = headers[0]
    end = next((i for i in range(start + 1, len(lines))
                if re.match(r"^\s*\[[^\]]+\]\s*$", lines[i])), len(lines))
    indexes = [i for i in range(start + 1, end) if re.match(r"^\s*prefix\s*=", lines[i])]
    if len(indexes) > 1:
        print(f"[WARN] duplicate keys.prefix entries left unchanged: {target}")
        sys.exit(3)
    if indexes:
        lines[indexes[0]] = prefix
    else:
        lines.insert(start + 1, prefix)
else:
    if lines and lines[-1].strip():
        lines.append("")
    lines.extend(template.rstrip().splitlines())
rendered = "\n".join(lines).rstrip() + "\n"
if old == rendered:
    print(f"[OK] {target} already current")
    sys.exit(0)
if target.exists():
    shutil.copy2(target, target.with_name(target.name + ".bak.oh-my-agent-env"))
fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"[OK] set Herdr prefix in {target}")
PY
}

# merge_bash_aliases TARGET [TAG BODY]: one marker block per TAG (default: the
# Herdr wrapper aliases), replaced in place, appended when absent.
merge_bash_aliases() {
  local target="$1"
  python3 - "$target" "${2:-herdr-agents}" "${3:-}" <<'PY'
import os, re, shutil, sys, tempfile
from pathlib import Path

target, tag, body = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
target.parent.mkdir(parents=True, exist_ok=True)
# Markers keep the pre-rename name (oh-my-agent-env): files on every machine
# already carry it, and a new name would insert a second block.
begin = f"# >>> oh-my-agent-env:{tag} >>>"
end = f"# <<< oh-my-agent-env:{tag} <<<"
body = body or """# Herdr-aware wrappers are vanilla-equivalent outside Herdr.
if [ -x "$HOME/.local/bin/gjc-herdr" ]; then alias gjc='gjc-herdr'; fi
if [ -x "$HOME/.local/bin/omo-herdr" ]; then alias omo='omo-herdr'; fi"""
block = f"{begin}\n{body.rstrip()}\n{end}"
old = target.read_text(encoding="utf-8") if target.exists() else ""
if (begin in old) != (end in old):
    print(f"[WARN] broken {tag} managed block left unchanged: {target}")
    sys.exit(3)
# Migrate the one-off block used before this became repository-managed.
base = re.sub(
    r"\n?# >>> Herdr agent recognition \(added [^)]+\) >>>.*?"
    r"# <<< Herdr agent recognition \(added [^)]+\) <<<\n?",
    "\n", old, flags=re.S)
if begin in base:
    head, rest = base.split(begin, 1)
    _, tail = rest.split(end, 1)
    rendered = (head.rstrip() + "\n\n" if head.strip() else "") + block + tail
else:
    rendered = base.rstrip() + ("\n\n" if base.strip() else "") + block + "\n"
rendered = rendered.rstrip() + "\n"
if old == rendered:
    print(f"[OK] {target} {tag} block already current")
    sys.exit(0)
if target.exists():
    shutil.copy2(target, target.with_name(target.name + ".bak.oh-my-agent-env"))
fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"[OK] installed {tag} block in {target}")
PY
}

sync_herdr_skill() {
  # Repository-managed Herdr skills, one real SKILL.md per runtime scan root (GJC
  # refuses symlinked skills outside its scan root, so never symlink here):
  #   GJC     -> ~/.gjc/agent/skills   (verified: gjc skills discover)
  #   Claude  -> ~/.claude/skills      ($CONFIG_DIR; Claude Code convention)
  #   Codex   -> ~/.codex/skills       (Codex's own skill dir; it does NOT read ~/.agents/skills)
  #   OMO/pi  -> ~/.agents/skills      (pi/omo global skill dir; OMO also reads ~/.claude/skills)
  # herdr-app covers the herdr-app/hc generation. The base `herdr` skill used to be
  # generated from `herdr --skill` (legacy 0.8 CLI, HERDR_ENV=1 only); agents read it
  # as "Herdr is unavailable" inside herdr-app terminals, so it is removed instead.
  local gjc_dir="${GJC_CODING_AGENT_DIR:-$HOME/.gjc/agent}"
  local claude_dir="${CONFIG_DIR:-$HOME/.claude}"
  local codex_dir="${CODEX_DIR:-$HOME/.codex}"
  local agents_dir="${AGENTS_DIR:-$HOME/.agents}"
  local root skill src dst n

  for root in "$gjc_dir/skills" "$claude_dir/skills" "$codex_dir/skills" "$agents_dir/skills"; do
    # Only the generated file: a user-authored sibling in the directory is kept.
    if [ -f "$root/herdr/SKILL.md" ] || [ -L "$root/herdr/SKILL.md" ]; then
      rm -f "$root/herdr/SKILL.md" && rmdir "$root/herdr" 2>/dev/null
      log_and_print "    [CLEAN] removed generated legacy herdr skill under $root"
    fi
  done

  for skill in herdr-council herdr-app; do
    src="$SCRIPT_DIR/skills/$skill/SKILL.md"
    n=0
    if [ ! -f "$src" ]; then
      log_and_print "    [WARN] $skill source missing: $src"
      WARNINGS=$((WARNINGS+1))
      continue
    fi
    for root in "$gjc_dir/skills" "$claude_dir/skills" "$codex_dir/skills" "$agents_dir/skills"; do
      if ! mkdir -p "$root/$skill"; then
        log_and_print "    [WARN] cannot create $root/$skill"
        WARNINGS=$((WARNINGS+1))
        continue
      fi
      dst="$root/$skill/SKILL.md"
      if [ -L "$dst" ] && ! rm -f "$dst"; then
        log_and_print "    [WARN] cannot replace linked $skill skill under $root"
        WARNINGS=$((WARNINGS+1))
        continue
      fi
      if [ -d "$dst" ]; then
        log_and_print "    [WARN] $skill target is a directory under $root"
        WARNINGS=$((WARNINGS+1))
        continue
      fi
      if cp "$src" "$dst" && [ -f "$dst" ] && [ ! -L "$dst" ]; then
        n=$((n+1))
      else
        log_and_print "    [WARN] cannot install $skill under $root"
        WARNINGS=$((WARNINGS+1))
      fi
    done
    if [ "$n" -eq 4 ]; then
      log_and_print "    [OK] $skill skill installed (4 scan roots: gjc/claude/codex/agents)"
    elif [ "$n" -gt 0 ]; then
      log_and_print "    [WARN] $skill skill partially installed ($n/4 scan roots)"
    fi
  done
}

sync_herdr_app() {
  # herdr-app (Mac GUI + `hc` on every machine) status helpers from runtimes/herdr-app:
  #   bin         -> ~/.local/bin links (repo stays the single source)
  #   agy hooks   -> ~/.gemini/config/hooks.json group "herdr-agy-app" (other groups kept)
  #   tmux        -> ~/.tmux.conf marker block; OMS panel mains report via herdr-tmux-osc
  #   mod, layout -> ~/.config/herdr-app, Mac only, copied: herdr-app writes next to them
  local src="$SCRIPT_DIR/runtimes/herdr-app" app_dir="$HOME/.config/herdr-app"
  [ -d "$src" ] || return 0
  mkdir -p "$HOME/.local/bin"
  make_link "$src/bin/agy-app-herdr" "$HOME/.local/bin/agy-app-herdr"
  make_link "$src/bin/herdr-tmux-osc" "$HOME/.local/bin/herdr-tmux-osc"
  if command -v herdr-app >/dev/null 2>&1; then
    make_link "$src/bin/herdr-keep-missing" "$HOME/.local/bin/herdr-keep-missing"
    if mkdir -p "$app_dir/mods/my-agents" "$app_dir/layouts" \
      && cp -f "$src/mods/my-agents/main.js" "$src/mods/my-agents/mod.json" "$app_dir/mods/my-agents/" \
      && cp -f "$src/layouts/my-layout.json" "$app_dir/layouts/"; then
      log_and_print "    [OK] herdr-app my-agents mod + my-layout installed -> $app_dir"
    else
      log_and_print "    [FAIL] herdr-app mod/layout install"
      ERRORS=$((ERRORS+1))
    fi
  fi

  if [ -d "$HOME/.gemini" ]; then
    python3 - "$HOME/.gemini/config/hooks.json" "$HOME/.local/bin/agy-app-herdr" <<'PY' \
      || { log_and_print "    [FAIL] agy hooks merge"; ERRORS=$((ERRORS+1)); }
import json, os, sys
from pathlib import Path
target, cmd = Path(sys.argv[1]), sys.argv[2]
text = target.read_text() if target.exists() else ""
data = json.loads(text) if text.strip() else {}
if not isinstance(data, dict):
    sys.exit(f"    [FAIL] {target} is not a JSON object")
def hook(ev):
    return {"type": "command", "command": f"{cmd} hook {ev}", "timeout": 10}
group = {ev: [hook(ev)] for ev in ("SessionStart", "PreInvocation", "Stop")}
group.update({ev: [{"matcher": "*", "hooks": [hook(ev)]}] for ev in ("PreToolUse", "PostToolUse")})
if data.get("herdr-agy-app") == group:
    print(f"    [OK] {target} herdr-agy-app hooks already current")
    sys.exit(0)
data["herdr-agy-app"] = group
target.parent.mkdir(parents=True, exist_ok=True)
tmp = target.with_name(f".{target.name}.{os.getpid()}")
tmp.write_text(json.dumps(data, indent=2) + "\n")
os.replace(tmp, target)
print(f"    [OK] merged herdr-agy-app hooks into {target}")
PY
  fi

  command -v tmux >/dev/null 2>&1 || return 0
  python3 - "$HOME/.tmux.conf" "$src/tmux.conf" <<'PY' \
    || { log_and_print "    [FAIL] tmux.conf merge"; ERRORS=$((ERRORS+1)); return 0; }
import os, sys
from pathlib import Path
target, managed = Path(sys.argv[1]), Path(sys.argv[2]).read_text().strip()
begin, end = "# >>> oh-my-agent-env:herdr-app >>>", "# <<< oh-my-agent-env:herdr-app <<<"
old = target.read_text() if target.exists() else ""
managed_lines = set(managed.splitlines())
lines, inside = [], False
for line in old.splitlines():
    if line == begin:
        inside = True
    elif line == end:
        inside = False
    elif not inside and line.strip() not in managed_lines:
        lines.append(line)  # unmarked copies of managed lines (hand install) are dropped
body = "\n".join(lines).rstrip()
new = (body + "\n\n" if body else "") + f"{begin}\n{managed}\n{end}\n"
if new == old:
    print(f"    [OK] {target} herdr-app block already current")
    sys.exit(0)
tmp = target.with_name(f".{target.name}.{os.getpid()}")
tmp.write_text(new)
os.replace(tmp, target)
print(f"    [OK] installed herdr-app block in {target}")
PY
  # A running server misses ~/.tmux.conf changes: hook it now (no server -> no-op).
  "$HOME/.local/bin/herdr-tmux-osc" install >/dev/null 2>&1 || true
}

sync_gjc_settings() {
  local file="$SCRIPT_DIR/runtimes/gjc/settings.conf" key value applied=0 failed=0
  [ -f "$file" ] || return 0
  if ! command -v gjc >/dev/null 2>&1; then
    log_and_print "    [SKIP] GJC settings — gjc not installed yet"
    return 0
  fi
  while read -r key value; do
    case "$key" in ''|'#'*) continue ;; esac
    [ -n "$value" ] || continue
    # Strip one layer of surrounding double quotes so multi-word values work.
    case "$value" in '"'*'"') value="${value#\"}"; value="${value%\"}" ;; esac
    if gjc config set "$key" "$value" </dev/null >/dev/null 2>&1; then
      applied=$((applied+1))
    else
      failed=$((failed+1))
      log_and_print "    [WARN] GJC setting rejected: $key=$value"
      WARNINGS=$((WARNINGS+1))
    fi
  done < "$file"
  # `if`, not `[ ] &&`: a false test as the last command becomes the function's
  # status, and setup.sh's `set -e` would then abort every later sync step.
  if [ "$failed" -eq 0 ]; then log_and_print "    [OK] GJC settings applied ($applied)"; fi
}

sync_gjc_hooks() {
  # Deploy attitude-gate pre_tool_use hooks to the user configDir so they apply
  # to every GJC session. Hooks are inert until opted in via attitude-gate.json
  # (default enabled=false), so deploying them is safe.
  local src="$SCRIPT_DIR/runtimes/gjc/hooks/pre" dest="$HOME/.gjc/agent/hooks/pre"
  [ -d "$src" ] || return 0
  mkdir -p "$dest" || { log_and_print "    [WARN] cannot create $dest"; WARNINGS=$((WARNINGS+1)); return 0; }
  local n=0
  for f in "$src"/*.ts; do
    [ -e "$f" ] || continue
    if cp -f "$f" "$dest/"; then n=$((n+1)); else log_and_print "    [WARN] hook copy failed: $(basename "$f")"; WARNINGS=$((WARNINGS+1)); fi
  done
  # Seed the configs only if absent — never overwrite the user's enabled/gate choices.
  local cfg="$HOME/.gjc/agent/hooks/attitude-gate.json"
  if [ ! -f "$cfg" ] && [ -f "$SCRIPT_DIR/runtimes/gjc/hooks/attitude-gate.example.json" ]; then
    cp -f "$SCRIPT_DIR/runtimes/gjc/hooks/attitude-gate.example.json" "$cfg" \
      && log_and_print "    [OK] seeded attitude-gate.json (disabled by default; set enabled=true to activate)"
  fi
  # graft-uptake nudge for the discovery surfaces (pre/{search,search_tool_bm25,
  # find,read}.ts + grep-like pre/bash.ts -> _surface.ts/_graft-nudge.ts). All hook
  # files ship in $src and are copied by the loop above. Same seed-if-absent policy;
  # default enabled=false so a global deploy is a NO-OP until opted in via
  # ~/.gjc/agent/hooks/graft-nudge.json or a project override.
  local gcfg="$HOME/.gjc/agent/hooks/graft-nudge.json"
  if [ ! -f "$gcfg" ] && [ -f "$SCRIPT_DIR/runtimes/gjc/hooks/graft-nudge.example.json" ]; then
    cp -f "$SCRIPT_DIR/runtimes/gjc/hooks/graft-nudge.example.json" "$gcfg" \
      && log_and_print "    [OK] seeded graft-nudge.json (disabled by default; set enabled=true to activate)"
  fi
  # graphify-freshness nudge for the `search` tool (pre/search.ts -> _graphify-nudge.ts).
  # Same seed-if-absent policy. The seed ships enabled=true but is a NO-OP in any repo
  # without graphify-out/graph.json, and only fires after graft was used this session.
  local pcfg="$HOME/.gjc/agent/hooks/graphify-nudge.json"
  if [ ! -f "$pcfg" ] && [ -f "$SCRIPT_DIR/runtimes/gjc/hooks/graphify-nudge.example.json" ]; then
    cp -f "$SCRIPT_DIR/runtimes/gjc/hooks/graphify-nudge.example.json" "$pcfg" \
      && log_and_print "    [OK] seeded graphify-nudge.json (enabled; no-op without graphify-out/graph.json)"
  fi
  if [ "$n" -gt 0 ]; then log_and_print "    [OK] GJC attitude-gate + graft-nudge + graphify-nudge hooks deployed ($n files)"; fi
}

sync_omo_settings() {
  local src="$SCRIPT_DIR/runtimes/omo/settings.json" dest="$HOME/.omo/agent/settings.json"
  [ -f "$src" ] || return 0
  [ -d "$HOME/.omo/agent" ] || { log_and_print "    [SKIP] OMO settings — ~/.omo/agent absent"; return 0; }
  if python3 - "$dest" "$src" <<'PY'
import json,os,sys,tempfile
dest,src=sys.argv[1],sys.argv[2]
managed={k:v for k,v in json.load(open(src,encoding="utf-8")).items() if not k.startswith("_")}
try: cur=json.load(open(dest,encoding="utf-8"))
except Exception: cur={}
if not isinstance(cur,dict): cur={}
def merge(base,over):
    for k,v in over.items():
        if isinstance(v,dict) and isinstance(base.get(k),dict): merge(base[k],v)
        else: base[k]=v
merge(cur,managed)
os.makedirs(os.path.dirname(dest),exist_ok=True)
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(dest))
with os.fdopen(fd,"w",encoding="utf-8") as f:
    json.dump(cur,f,indent=2,ensure_ascii=False); f.write("\n")
os.replace(tmp,dest)
PY
  then
    log_and_print "    [OK] OMO settings merged"
  else
    log_and_print "    [FAIL] OMO settings merge"
    ERRORS=$((ERRORS+1))
  fi
}

sync_omo_herdr_extension() {
  # One extension supports both generations: OSC 7501 (app=pi) for herdr-core,
  # pane.report_agent (agent=omo) for legacy Herdr. Outside either host it is inert.
  # Create the extension directory even before OMO's first interactive launch.
  local src="$SCRIPT_DIR/runtimes/omo/extensions/herdr-omp-agent-state.ts"
  local agent_dir="${OMO_CODING_AGENT_DIR:-$HOME/.omo/agent}"
  local dest_dir="$agent_dir/extensions" dest
  dest="$dest_dir/herdr-omp-agent-state.ts"
  [ -f "$src" ] || return 0
  if mkdir -p "$dest_dir" && cp -f "$src" "$dest"; then
    log_and_print "    [OK] OMO herdr agent-state extension deployed -> $dest (OMO: /reload when idle)"
  else
    log_and_print "    [FAIL] OMO herdr agent-state extension deploy"
    ERRORS=$((ERRORS+1))
  fi
}

# User additions loaded beside OMS's global rules: Claude reads ~/.claude/rules/*.md,
# OMO (pi) reads its agentDir AGENTS.md. OMS owns CLAUDE.md/AGENTS.md themselves.
sync_user_agent_rules() {
  local omo_dir="${OMO_CODING_AGENT_DIR:-$HOME/.omo/agent}" f
  for f in "$SCRIPT_DIR"/runtimes/claude/rules/*.md; do
    [ -f "$f" ] && make_link "$f" "${CONFIG_DIR:-$HOME/.claude}/rules/$(basename "$f")"
  done
  [ -f "$SCRIPT_DIR/runtimes/omo/AGENTS.md" ] && make_link "$SCRIPT_DIR/runtimes/omo/AGENTS.md" "$omo_dir/AGENTS.md"
  return 0
}

retract_gjc_graft_mcp() {
  # graft's code-graph reaches GJC through the graft-nudge pre-hook (sync_gjc_hooks),
  # NOT an MCP server: a lazy-activated MCP tool sat unused behind bm25 discovery,
  # while the hook drives uptake on the `search` path. So actively unregister any
  # graft MCP a previous sync left behind — this converges every already-provisioned
  # machine, not just fresh installs (removing the `add` alone would strand stale
  # entries). No-op when gjc is absent or no graft MCP is registered.
  command -v gjc >/dev/null 2>&1 || return 0
  gjc mcp list </dev/null 2>/dev/null | grep -qE '^graft[[:space:]]' || return 0
  if gjc mcp remove graft </dev/null >/dev/null 2>&1; then
    log_and_print "    [OK] GJC graft MCP unregistered (superseded by graft-nudge hook)"
  else
    log_and_print "    [WARN] GJC graft MCP present but could not be removed — run: gjc mcp remove graft"
    WARNINGS=$((WARNINGS+1))
  fi
}

sync_graft_hooks() {
  # Global graft-uptake hooks for Claude Code and Codex — the claude/codex
  # counterparts of GJC's graft-nudge pre-hook. graft's own user-level installers
  # write these outside every working tree (~/.claude, ~/.codex), so they fire in
  # EVERY repo opened with the agent, nudging the model to prefer graft over raw
  # grep/read.
  #
  # We call graft's exported global installers directly (by file URL) so the shims
  # always match the installed graft version, then STRIP the claude MCP entry graft
  # insists on writing: this harness drives graft uptake through hooks, not MCP.
  # Codex writes no MCP, so nothing to strip there. graft re-adds the claude MCP on
  # every run, so the strip is unconditional post-processing (end state is idempotent:
  # hooks present, no MCP).
  #
  # graft's deep dist modules are absent from its package "exports", so they must be
  # imported by file URL, not bare specifier. This couples us to graft's dist layout
  # and is fragile across upgrades by design — the accepted cost of hook-based uptake
  # without MCP (option A). A failed import fails open with a WARN.
  command -v graft >/dev/null 2>&1 || { log_and_print "    [SKIP] graft hooks — graft not installed yet"; return 0; }
  command -v node  >/dev/null 2>&1 || { log_and_print "    [SKIP] graft hooks — node not found"; return 0; }
  local gcli ghosts
  gcli="$(readlink -f "$(command -v graft)" 2>/dev/null)" || gcli=""
  ghosts="$(dirname "$gcli")/hosts"
  if [ ! -f "$ghosts/claude-global.js" ] || [ ! -f "$ghosts/codex-hooks.js" ]; then
    log_and_print "    [WARN] graft hooks — unexpected graft dist layout ($ghosts); run: graft init"
    WARNINGS=$((WARNINGS+1)); return 0
  fi
  if GRAFT_HOSTS="$ghosts" node --input-type=module >/dev/null 2>&1 <<'NODE'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
const hosts = process.env.GRAFT_HOSTS, home = process.env.HOME;
const cg = await import(pathToFileURL(join(hosts, "claude-global.js")).href);
const ch = await import(pathToFileURL(join(hosts, "codex-hooks.js")).href);
// Codex: self-guards on ~/.codex existing; never writes MCP.
ch.installCodexHooks(home);
// Claude: only wire when ~/.claude exists (agent set up). Strip the mcpServers.graft
// entry graft always adds — this harness uses hooks, not MCP, for graft.
if (existsSync(join(home, ".claude"))) {
  cg.installClaudeGlobal(home);
  const cj = join(home, ".claude.json");
  if (existsSync(cj)) {
    try {
      const d = JSON.parse(readFileSync(cj, "utf8"));
      const m = d && d.mcpServers;
      if (m && typeof m === "object" && "graft" in m) {
        delete m.graft;
        if (Object.keys(m).length === 0) delete d.mcpServers;
        writeFileSync(cj, JSON.stringify(d, null, 2) + "\n");
      }
    } catch { /* unparseable ~/.claude.json — leave it for the user */ }
  }
}
NODE
  then
    log_and_print "    [OK] graft uptake hooks wired (claude/codex where present; MCP stripped)"
  else
    log_and_print "    [WARN] graft hooks install failed (graft internals may have changed) — run: graft init"
    WARNINGS=$((WARNINGS+1))
  fi
}

sync_graphify_hooks() {
  # Global graphify-FRESHNESS hooks for Claude Code and Codex — the claude/codex
  # counterparts of GJC's graphify-nudge, and the companion to sync_graft_hooks.
  # graft self-syncs on every edit; graphify's AST graph does not, so after the
  # model edits code the graph is stale. These PostToolUse hooks fire after an edit
  # tool and, if a graphify graph exists AND has not already been nudged since its
  # last build, inject a one-shot nudge to run `graphify update .` (AST-only, $0).
  #
  # Unlike graft (whose dist ships global installers), graphify has no hook
  # installer, so the harness authors the hook. It is a self-contained inline shell
  # command — no shim file, no stdin parse — brick-safe by construction: no
  # graphify-out/graph.json => exit 0 (no-op); dedup via a git-ignored marker
  # (graphify-out/.graphify-nudged) so it nudges once per build->edit cycle, not on
  # every edit. `graphify update` bumps graph.json mtime past the marker, re-arming.
  #
  # Replaces (does not stack) any prior graphify entry: the command carries a stable
  # marker substring (graphify-out/.graphify-nudged) used to find and replace it.
  command -v python3 >/dev/null 2>&1 || { log_and_print "    [SKIP] graphify hooks — python3 not found"; return 0; }
  if python3 - <<'PY'
import json, os, sys
home = os.environ["HOME"]
MARKER = "graphify-out/.graphify-nudged"
targets = [
    (os.path.join(home, ".claude", "settings.json"), "Write|Edit|MultiEdit"),
    (os.path.join(home, ".codex", "hooks.json"), "apply_patch|Write|Edit|MultiEdit"),
]
ac = (
    "graphify: 코드가 그래프 빌드 이후 변경됨 — `graphify update .` "
    "(AST 전용, API 비용 0, --deep 아님)로 그래프를 최신화한 뒤 "
    '`graphify query "<질의>"` 로 조회하라.'
)
payload = json.dumps(
    {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ac}},
    ensure_ascii=False,
)
def sq(s):
    return "'" + s.replace("'", "'\\''") + "'"
cmd = (
    "g=graphify-out/graph.json; m=graphify-out/.graphify-nudged; "
    '[ -f "$g" ] || exit 0; '
    'if [ -f "$m" ] && [ "$m" -nt "$g" ]; then exit 0; fi; '
    ': > "$m" 2>/dev/null; printf %s ' + sq(payload)
)
changed = []
for path, matcher in targets:
    if not os.path.isdir(os.path.dirname(path)):
        continue  # agent not set up -> nothing to wire
    try:
        cur = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    except Exception:
        print("skip-unparseable " + path)
        continue
    if not isinstance(cur, dict):
        print("skip-nondict " + path)
        continue
    hooks = cur.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        print("skip-hooks " + path)
        continue
    lst = hooks.get("PostToolUse")
    if not isinstance(lst, list):
        lst = []
    lst = [e for e in lst if MARKER not in json.dumps(e, ensure_ascii=False)]
    lst.append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd, "timeout": 10000}]})
    hooks["PostToolUse"] = lst
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cur, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
    changed.append(os.path.basename(os.path.dirname(path)))
print("changed: " + (",".join(changed) if changed else "(none)"))
PY
  then
    log_and_print "    [OK] graphify freshness hooks wired (claude/codex where present)"
  else
    log_and_print "    [WARN] graphify hooks install failed"
    WARNINGS=$((WARNINGS+1))
  fi
}

sync_gjc_default_profile() {
  local profile
  profile="$(tr -d '[:space:]' < "$SCRIPT_DIR/runtimes/gjc/default-profile")"
  if command -v gjc >/dev/null 2>&1; then
    if gjc config set modelProfile.default "$profile" </dev/null >/dev/null 2>&1; then
      log_and_print "    [OK] GJC default profile: $profile"
    else
      log_and_print "    [WARN] GJC installed but default profile could not be set"
      WARNINGS=$((WARNINGS+1))
    fi
  else
    log_and_print "    [SKIP] GJC profile — gjc not installed yet"
  fi
}

sync_agent_cli_configs() {
  local gjc_dir="${GJC_CODING_AGENT_DIR:-$HOME/.gjc/agent}"
  local omo_dir="${OMO_CODING_AGENT_DIR:-$HOME/.omo/agent}"
  local herdr_dir="${HERDR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr}"
  local rc
  echo "[6b] GJC / OMO / Herdr portable configuration"

  rc=0; merge_agent_keybindings "$gjc_dir/keybindings.json" "$SCRIPT_DIR/runtimes/gjc/keybindings.json" || rc=$?
  [ "$rc" -eq 0 ] || { log_and_print "    [FAIL] GJC keybindings merge (rc=$rc)"; ERRORS=$((ERRORS+1)); }
  rc=0; merge_agent_keybindings "$omo_dir/keybindings.json" "$SCRIPT_DIR/runtimes/omo/keybindings.json" || rc=$?
  [ "$rc" -eq 0 ] || { log_and_print "    [FAIL] OMO keybindings merge (rc=$rc)"; ERRORS=$((ERRORS+1)); }
  rc=0; merge_herdr_config "$herdr_dir/config.toml" "$SCRIPT_DIR/runtimes/herdr/config.toml" || rc=$?
  [ "$rc" -eq 0 ] || { log_and_print "    [FAIL] Herdr config merge (rc=$rc)"; ERRORS=$((ERRORS+1)); }

  mkdir -p "$HOME/.local/bin"
  make_link "$SCRIPT_DIR/runtimes/herdr/gjc-herdr" "$HOME/.local/bin/gjc-herdr"
  make_link "$SCRIPT_DIR/runtimes/herdr/omo-herdr" "$HOME/.local/bin/omo-herdr"
  merge_bash_aliases "$HOME/.bashrc" || { log_and_print "    [FAIL] Bash alias merge"; ERRORS=$((ERRORS+1)); }
  # Both files: some machines' .bashrc sources .bash_profile, so chaining one to
  # the other could loop. shell/bashrc.sh guards against a second load instead.
  local rc_line rc_file
  rc_line="[ -f \"${SCRIPT_DIR/#$HOME/\$HOME}/shell/bashrc.sh\" ] && . \"${SCRIPT_DIR/#$HOME/\$HOME}/shell/bashrc.sh\""
  for rc_file in "$HOME/.bashrc" "$HOME/.bash_profile"; do
    merge_bash_aliases "$rc_file" shell "# Shared shell settings; machine-only lines stay outside this block.
$rc_line" || { log_and_print "    [FAIL] shell block merge: $rc_file"; ERRORS=$((ERRORS+1)); }
  done
  sync_gjc_default_profile
  sync_gjc_settings
  sync_gjc_hooks
  sync_omo_settings
  sync_omo_herdr_extension
  sync_user_agent_rules
  sync_herdr_skill
  sync_herdr_app
  retract_gjc_graft_mcp
  sync_graft_hooks
  sync_graphify_hooks

  if command -v herdr >/dev/null 2>&1; then
    herdr config check >/dev/null 2>&1 || { log_and_print "    [WARN] Herdr rejected managed config"; WARNINGS=$((WARNINGS+1)); }
    [ "${HERDR_ENV:-}" = "1" ] || herdr server reload-config >/dev/null 2>&1 || true
  fi
}

sync_agent_cli_install() {
  echo "[6c] GJC / OMO / Herdr installation"
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:$USER_NPM_PREFIX/bin:$PATH"

  if command -v herdr >/dev/null 2>&1; then
    log_and_print "    [OK] Herdr installed -> $(command -v herdr)"
  elif command -v curl >/dev/null 2>&1; then
    log_and_print "    Installing Herdr from herdr.dev..."
    run_with_timeout "Herdr install" "curl -fsSL https://herdr.dev/install.sh | sh" | tail -3 || true
    command -v herdr >/dev/null 2>&1 \
      && log_and_print "    [OK] Herdr installed -> $(command -v herdr)" \
      || { log_and_print "    [WARN] Herdr install failed"; WARNINGS=$((WARNINGS+1)); }
  else
    log_and_print "    [SKIP] Herdr — curl not found"
    WARNINGS=$((WARNINGS+1))
  fi

  if command -v omo >/dev/null 2>&1; then
    log_and_print "    [OK] OMO installed -> $(command -v omo)"
  else
    log_and_print "    Installing OMO (npm package omo-ai)..."
    run_with_timeout "OMO install" "$NPM_USER_ENV npm install -g omo-ai < /dev/null" | tail -3 || true
    command -v omo >/dev/null 2>&1 \
      && log_and_print "    [OK] OMO installed -> $(command -v omo)" \
      || { log_and_print "    [WARN] OMO install failed"; WARNINGS=$((WARNINGS+1)); }
  fi

  if ! command -v bun >/dev/null 2>&1; then
    if command -v curl >/dev/null 2>&1; then
      log_and_print "    Installing Bun (required by GJC)..."
      run_with_timeout "Bun install" "curl -fsSL https://bun.sh/install | bash" | tail -3 || true
      export PATH="$HOME/.bun/bin:$PATH"
    else
      log_and_print "    [SKIP] Bun/GJC — curl not found"
    fi
  fi
  if command -v gjc >/dev/null 2>&1; then
    log_and_print "    [OK] GJC installed -> $(command -v gjc)"
  elif command -v bun >/dev/null 2>&1; then
    log_and_print "    Installing GJC (bun install -g gajae-code)..."
    run_with_timeout "GJC install" "bun install -g gajae-code < /dev/null" | tail -3 || true
    command -v gjc >/dev/null 2>&1 \
      && log_and_print "    [OK] GJC installed -> $(command -v gjc)" \
      || { log_and_print "    [WARN] GJC install failed"; WARNINGS=$((WARNINGS+1)); }
  else
    log_and_print "    [WARN] GJC unavailable because Bun is not installed"
    WARNINGS=$((WARNINGS+1))
  fi

  # First sync on a fresh machine reaches this only after GJC was installed.
  sync_gjc_default_profile
  sync_gjc_settings
  sync_gjc_hooks
  sync_omo_settings
  sync_omo_herdr_extension
  sync_user_agent_rules
  sync_herdr_skill
  sync_herdr_app
  retract_gjc_graft_mcp
  sync_graft_hooks
  sync_graphify_hooks
}
