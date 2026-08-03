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
import sys, os, shutil, re
cfg = sys.argv[1]


def load_min(path):
    """Just enough TOML for the file sync writes: `command` under
    [mcp_servers.NAME] and `PATH` under [mcp_servers.NAME.env].

    Depth is the whole point. This config really does carry deeper tables —
    [mcp_servers.context-mode.tools.ctx_search] and friends — and reading a
    `command` out of one of those, or treating `.tools.` as `.env.`, would
    answer the question about the wrong thing. So a name is only a server at
    exactly two segments, and only a three-segment table ending in `env`
    contributes PATH. Bare keys and basic strings only, which is all sync emits.
    """
    servers, table = {}, None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            header = re.match(r"^\[([^\[\]]+)\]$", line)
            if header:
                table = header.group(1).strip()
                continue
            if table is None:
                continue
            parts = table.split(".")
            if parts[0] != "mcp_servers" or len(parts) < 2:
                continue
            pair = re.match(r'^([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*"([^"]*)"\s*$', line)
            if not pair:
                continue
            key, val = pair.group(1), pair.group(2)
            if len(parts) == 2 and key == "command":
                servers.setdefault(parts[1], {})["command"] = val
            elif len(parts) == 3 and parts[2] == "env" and key == "PATH":
                servers.setdefault(parts[1], {}).setdefault("env", {})["PATH"] = val
    return servers


# python<3.11 has no tomllib, and skipping used to emit __WARN__0 — the same
# zero warnings a clean pass emits. On this machine (3.10.12) that meant the
# entire runtime-dependency check had never once run, while doctor reported
# health. "Could not check" and "checked, fine" must not render the same.
parsed_with = "tomllib"
try:
    import tomllib
except ImportError:
    tomllib = None
try:
    if tomllib is not None:
        m = tomllib.load(open(cfg, "rb")).get("mcp_servers", {})
    else:
        m = load_min(cfg)
        parsed_with = "minimal parser"
except Exception as e:
    print(f"  [WARN] runtime dep check: cannot read config.toml ({e})"); print("__WARN__1"); sys.exit(0)

# A parser that reads the file but finds nothing would otherwise report the same
# silence as a config with no MCP servers in it.
if not m:
    try:
        # Quoted forms too (["mcp_servers"."x"]) — the minimal parser reads bare
        # keys only, and a header spelled a way it skips must still be reported
        # rather than counted as "no servers configured".
        raw = open(cfg, encoding="utf-8").read()
        names_present = re.search(r'^\s*\[\s*"?mcp_servers"?\s*\.', raw, re.M) is not None
    except OSError:
        names_present = False
    if names_present:
        print(f"  [WARN] runtime dep check: config.toml names MCP servers the {parsed_with} could not read")
        print("__WARN__1"); sys.exit(0)
if tomllib is None:
    print("  [NOTE] runtime dep check parsed config.toml without tomllib (python<3.11)")
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
  echo "[ Serena project config ]"
  # Registered is not the same as able to start, and that gap is exactly how
  # serena failed here: the entry resolved, the binary existed, and the server
  # still died before the handshake because .serena/project.yml had been written
  # by a DIFFERENT serena. sync used to register upstream HEAD in three separate
  # places — Claude's registry, ~/.codex/config.toml, and agy's shared
  # config/mcp_config.json — and HEAD writes `language_servers:` where the pinned
  # release requires `languages:`, with no migration between the two spellings.
  # Proven by control: with the file at `languages:`, running the release left it
  # alone and running the HEAD build flipped it.
  #
  # The symptom carried no diagnosis. `[MISS] serena` arrived with no reason
  # attached, because the reason logic asks whether the COMMAND resolves and the
  # command resolved fine. Fixing the three registrations removed the cause, but
  # missing one of them is silent again until someone restarts — which is what
  # happened. This is the check that speaks up instead.
  #
  # Required keys are read out of the INSTALLED build, not hardcoded, so this
  # asks what this machine's serena demands rather than what it demanded the day
  # this was written.
  _sr_bin="$(command -v serena 2>/dev/null || true)"
  _sr_cfg="$SCRIPT_DIR/.serena/project.yml"
  if [ -z "$_sr_bin" ]; then
    echo "  [SKIP] serena not installed"
  elif [ ! -f "$_sr_cfg" ]; then
    echo "  [SKIP] .serena/project.yml absent — this checkout is not serena-activated"
  else
    _sr_py="$(sed -n '1s/^#!//p' "$_sr_bin" 2>/dev/null)"
    _sr_req=""
    if [ -n "$_sr_py" ] && [ -x "$_sr_py" ]; then
      _sr_req="$(maybe_timeout 30 "$_sr_py" -c 'from serena.config.serena_config import ProjectConfig; print(" ".join(sorted(ProjectConfig.FIELDS_WITHOUT_DEFAULTS)))' 2>/dev/null || true)"
    fi
    if [ -z "$_sr_req" ]; then
      # Not "fine" — we could not ask. Staying quiet here is the same shape as
      # the codex runtime dep check, which sat unrun for a whole python version
      # while reporting the zero warnings a clean pass reports.
      echo "  [WARN] could not read the required keys from the installed serena — schema unverified"
      WARNINGS=$((WARNINGS+1))
    else
      # Top-level keys only: the loader reads the document root, so a `languages:`
      # nested under some other table would not satisfy it either.
      _sr_present="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*:' "$_sr_cfg" | tr -d ':' | sort -u)"
      _sr_missing=""
      for _sr_k in $_sr_req; do
        printf '%s\n' "$_sr_present" | grep -qx "$_sr_k" \
          || _sr_missing="${_sr_missing:+$_sr_missing }$_sr_k"
      done
      if [ -n "$_sr_missing" ]; then
        echo "  [MISS] .serena/project.yml lacks required key(s): $_sr_missing"
        echo "         serena raises KeyError before the MCP handshake, so it reports as"
        echo "         a connection failure with no reason. Another build wrote this file:"
        echo "         run 'setup.sh sync' to repoint every registration at the installed"
        echo "         release, then restore the key."
        WARNINGS=$((WARNINGS+1))
      else
        echo "  [OK] .serena/project.yml carries every key this serena requires ($_sr_req)"
      fi
    fi
  fi

  echo ""

}
