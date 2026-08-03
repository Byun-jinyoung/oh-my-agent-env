# oh-my-agent-env: sync domain - frameworks.sh
# Sourced by lib/sync.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

# [9b][9c][10] Codex/Antigravity MCP entries, Serena hardening, frameworks (GSD/RTK/Graphify/CRG/codegraph)
sync_agent_mcp_frameworks() {
  # [9b] Codex / Antigravity MCP registration (for triangle-review + codebase-scan)
  # serena와 code-review-graph는 ~/.codex/config.toml과
  # ~/.gemini/config/mcp_config.json에 별도 등록되어야 함
  # (claude mcp add는 Claude Code에만 등록됨; agy CLI/IDE는 ~/.gemini/config/
  # mcp_config.json을 shared MCP source of truth로 본다 — top-level
  # ~/.gemini/settings.json mcpServers는 안 본다.)
  log_and_print "[9b] Codex/Antigravity MCP entries"
  if command -v python3 &>/dev/null; then
    python3 - "$CODEX_DIR" "$GEMINI_DIR" << 'PYEOF' | sed 's/^/    /'
import json, os, sys
from pathlib import Path

codex_dir, gemini_dir = sys.argv[1], sys.argv[2]

# External MCPs needed by triangle-review + codebase-scan
WANTED = {
    # The pinned release on PATH, not upstream HEAD. setup.sh cmd_oma [0]
    # installs it with `uv tool install serena-agent` and oma's .mcp.json runs
    # `serena`, so registering `uvx --from git+…` here made Codex start a SECOND
    # build of the same tool against the SAME .serena/project.yml — and the two
    # schemas have diverged. HEAD writes `language_servers:`; the release reads
    # `languages:` and raises KeyError before the handshake, and oma's own bridge
    # tests `/^languages:/m` and skips the project. So one Codex session was
    # enough to disconnect serena for Claude and oma both.
    "serena": {
        "command": "serena",
        "args": ["start-mcp-server"],
    },
    "code-review-graph": {
        "command": "code-review-graph",
        "args": ["serve"],
    },
    "context-mode": {
        "command": "context-mode",
    },
}

# --- Codex (TOML, ~/.codex/config.toml) ---
# (Note: ensure_codex_context_mode handles context-mode in Codex specifically)
codex_cfg = Path(codex_dir) / "config.toml"
codex_cfg.parent.mkdir(parents=True, exist_ok=True)
if not codex_cfg.exists():
    codex_cfg.write_text("")
    print(f"[CREATE] {codex_cfg}")
content = codex_cfg.read_text()

def has_codex_section(name):
    return f"[mcp_servers.{name}]" in content

added_codex = []
for name, spec in WANTED.items():
    if name == "context-mode": continue # Handled by ensure_codex_context_mode
    if has_codex_section(name):
        continue
    block = [f"\n[mcp_servers.{name}]",
             f'command = "{spec["command"]}"',
             "args = [" + ", ".join(f'"{a}"' for a in spec["args"]) + "]",
             ""]
    content += "\n".join(block)
    added_codex.append(name)

# Heal a section that already exists but names the other build. has_codex_section
# proves only that the NAME is taken — the same blind spot add_mcp had on the
# Claude side — so without this the `uvx --from git+…` entry written by earlier
# syncs outlives the fix above forever, and one Codex session is enough to put
# .serena/project.yml back into the schema neither the release nor oma can read.
healed = []
if "git+https://github.com/oraios/serena" in content:
    out, in_serena = [], False
    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            in_serena = stripped == "[mcp_servers.serena]"
        elif in_serena and stripped.startswith("args") and "git+" in stripped:
            line = 'args = ["start-mcp-server"]'
            healed.append("args")
        elif in_serena and stripped.startswith("command") and "uvx" in stripped:
            line = 'command = "serena"'
            healed.append("command")
        out.append(line)
    if healed:
        content = "\n".join(out) + ("\n" if content.endswith("\n") else "")

if added_codex or healed:
    codex_cfg.write_text(content)
    what = []
    if added_codex:
        what.append("added " + ", ".join(added_codex))
    if healed:
        what.append("repointed serena from git HEAD to the pinned release (" + ", ".join(healed) + ")")
    print(f"[OK] Codex: {'; '.join(what)} in {codex_cfg.name}")
else:
    print(f"[OK] Codex: serena + code-review-graph already in {codex_cfg.name}")

# --- Antigravity (shared MCP config at ~/.gemini/config/mcp_config.json) ---
# agy CLI and Antigravity IDE both read this file as the global/shared
# source of truth for MCP servers (per official Antigravity docs and
# verified via /mcp output). ~/.gemini/settings.json mcpServers (the
# pre-2026-05-19 gemini-cli location) is NOT picked up by agy.
# Hooks below still write to ~/.gemini/settings.json because context-mode's
# hook system was built for the gemini-cli hook schema; that's a separate
# concern from MCP routing.
agy_mcp_cfg = Path(gemini_dir) / "config" / "mcp_config.json"
agy_mcp_cfg.parent.mkdir(parents=True, exist_ok=True)
agy_data = {}
if agy_mcp_cfg.exists() and agy_mcp_cfg.stat().st_size > 0:
    try:
        agy_data = json.loads(agy_mcp_cfg.read_text())
    except json.JSONDecodeError:
        print(f"[WARN] {agy_mcp_cfg} unparseable — skipping mcp register (back up + edit manually)")
        agy_data = None

# settings.json is still loaded for the hooks block that follows
gemini_cfg = Path(gemini_dir) / "settings.json"
gemini_cfg.parent.mkdir(parents=True, exist_ok=True)
if gemini_cfg.exists():
    try:
        data = json.loads(gemini_cfg.read_text())
    except json.JSONDecodeError:
        print(f"[WARN] {gemini_cfg} unparseable — skipping (back up + edit manually)")
        sys.exit(0)
else:
    data = {}

# Dynamic path resolution for context-mode
import subprocess, os
def get_cm_paths():
    try:
        npm_root = subprocess.check_output(["npm", "root", "-g"], text=True).strip()
        bundle_path = os.path.join(npm_root, "context-mode", "cli.bundle.mjs")
        bin_path = subprocess.check_output(["which", "context-mode"], text=True).strip()
        if os.path.exists(bundle_path):
            return bundle_path, bin_path
    except:
        pass
    return None, "context-mode"

cm_path, cm_bin = get_cm_paths()

added_gemini = []
if agy_data is not None:
    mcp_servers = agy_data.setdefault("mcpServers", {})

    # Step 1: preserve any third-party mcpServers that were in the legacy
    # ~/.gemini/settings.json. Merge them into the new shared location BEFORE
    # stripping the legacy key, so user-managed entries (e.g. agentmemory)
    # don't get lost. oh-my-agent-env-managed entries (WANTED below) win on
    # conflict — they always reflect the canonical spec.
    legacy_mcp = data.get("mcpServers", {}) if isinstance(data, dict) else {}
    preserved = []
    for name, spec in legacy_mcp.items():
        if name not in mcp_servers:
            mcp_servers[name] = spec
            preserved.append(name)

    # Step 2: apply oh-my-agent-env's WANTED entries (overwrites legacy entries
    # of the same name with the canonical spec).
    for name, spec in WANTED.items():
        # Force update context-mode to ensure absolute path integrity
        if name == "context-mode" and cm_path:
            new_spec = {"command": "node", "args": [cm_path]}
            if mcp_servers.get(name) != new_spec:
                mcp_servers[name] = new_spec
                added_gemini.append(name)
            continue

        if name in mcp_servers and name not in preserved:
            continue
        mcp_servers[name] = spec
        added_gemini.append(name)

    agy_mcp_cfg.write_text(json.dumps(agy_data, indent=2))

    # Step 3: strip the now-redundant mcpServers from the legacy settings.json.
    # agy and Antigravity IDE don't read this location for MCPs anyway; leaving
    # the entries there is misleading on doctor output and on future debugging.
    if legacy_mcp:
        del data["mcpServers"]
        moved_label = (", ".join(legacy_mcp.keys())) or "(none)"
        if preserved:
            print(f"[OK] preserved third-party mcpServers ({', '.join(preserved)}) during migration")
        print(f"[OK] migrated mcpServers ({moved_label}) out of {gemini_cfg.name} into config/mcp_config.json")

# --- Strip oh-my-agent-env-managed gemini-cli hooks from legacy settings.json ---
# agy does not read settings.json hooks (verified: 0 fires across agy logs;
# import_manifest excludes hooks). The Gemini CLI does still read this file,
# but the user's policy is full transition to agy. So we stop writing
# context-mode gemini-cli hooks here and selectively strip any we previously
# wrote. Third-party hook entries (e.g., RTK's rtk-hook-gemini.sh) are
# preserved — the mcpServers regression taught us not to nuke the whole key.
hooks_data = data.get("hooks", {})
stripped = []
if isinstance(hooks_data, dict):
    for event in list(hooks_data.keys()):
        wrappers = hooks_data.get(event, [])
        if not isinstance(wrappers, list):
            continue
        new_wrappers = []
        for w in wrappers:
            if not isinstance(w, dict):
                new_wrappers.append(w)
                continue
            hs = w.get("hooks", [])
            kept = [h for h in hs
                    if not (isinstance(h, dict)
                            and "context-mode hook gemini-cli" in str(h.get("command", "")))]
            if not kept:
                # entire wrapper was a oh-my-agent-env entry — drop it
                stripped.append(f"{event}")
                continue
            if len(kept) != len(hs):
                w["hooks"] = kept
                stripped.append(f"{event}(partial)")
            new_wrappers.append(w)
        if new_wrappers:
            hooks_data[event] = new_wrappers
        else:
            del hooks_data[event]
    if not hooks_data:
        data.pop("hooks", None)

# Write back if mcpServers strip OR hooks strip changed anything
if bool(legacy_mcp) or stripped:
    gemini_cfg.write_text(json.dumps(data, indent=2, ensure_ascii=False))

if stripped:
    print(f"[OK] stripped oh-my-agent-env-managed gemini-cli hooks ({', '.join(stripped)}) from settings.json — agy ignores them; gemini-cli still reads any remaining hooks")
elif not legacy_mcp:
    print("[OK] Gemini: settings.json already clean")
PYEOF
  else
    log_and_print "    [SKIP] python3 not available"
  fi
  if command -v context-mode &>/dev/null; then
    ensure_codex_context_mode
  else
    log_and_print "    [WARN] context-mode missing. Install Node package first: npm install -g context-mode"
  fi
  # Harden the other Codex-side managed MCPs (serena/code-review-graph/antigravity-mcp)
  # with absolute command + env PATH so they resolve under Codex's spawn PATH.
  ensure_codex_mcp_paths

  # [9c] Serena hardening — disable browser auto-launch on MCP start
  # Dashboard stays enabled (useful for debugging via http://localhost:24282/dashboard/),
  # but no browser tab is auto-opened each time serena MCP boots.
  log_and_print "[9c] Serena hardening (web_dashboard_open_on_launch=false)"
  if [ -f "$SERENA_CONFIG" ] && command -v python3 &>/dev/null; then
    python3 - "$SERENA_CONFIG" << 'PYEOF' | sed 's/^/    /'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    print("[WARN] PyYAML missing — skipping. pip install pyyaml")
    sys.exit(0)

path = Path(sys.argv[1])
config = yaml.safe_load(path.read_text()) or {}
if config.get("web_dashboard_open_on_launch") is False:
    print("[OK] web_dashboard_open_on_launch already false")
else:
    # Preserve comments by doing a targeted line edit instead of full yaml.dump
    text = path.read_text()
    if "web_dashboard_open_on_launch:" in text:
        new = []
        for line in text.splitlines():
            if line.startswith("web_dashboard_open_on_launch:"):
                new.append("web_dashboard_open_on_launch: false")
            else:
                new.append(line)
        path.write_text("\n".join(new) + ("\n" if text.endswith("\n") else ""))
    else:
        with path.open("a") as f:
            f.write("\nweb_dashboard_open_on_launch: false\n")
    print("[OK] Set web_dashboard_open_on_launch: false")
PYEOF
  else
    log_and_print "    [SKIP] $SERENA_CONFIG not found or python3 missing"
  fi

  # [10] Frameworks
  log_and_print "[10] Frameworks"
  export PATH="$HOME/.local/bin:$PATH"

  # GSD
  # Detect via either old commands/ path or current skills/ layout (GSD restructured upstream).
  if ls "$CONFIG_DIR/commands/gsd"* &>/dev/null 2>&1 || ls -d "$CONFIG_DIR/skills/gsd-"* &>/dev/null 2>&1; then
    log_and_print "    [OK] GSD already installed"
  else

    log_and_print "    Installing GSD (npx get-shit-done-cc)..."
    # GSD installs by running bin/install.js which copies .md files to ~/.claude/commands/
    # npx is the official method; --yes prevents interactive prompt; stdin from /dev/null prevents hang
    run_with_timeout "GSD install" "npx --yes get-shit-done-cc@latest < /dev/null" | tail -3 || {
      # Fallback: download tarball and run install.js directly
      log_and_print "    [WARN] npx failed, trying manual install..."
      run_with_timeout "GSD manual install" \
        "cd /tmp && npm pack get-shit-done-cc@latest < /dev/null && tar xzf get-shit-done-cc-*.tgz && node package/bin/install.js && rm -rf package get-shit-done-cc-*.tgz" \
        | tail -3 || true
    }
  fi
  # RTK (cross-platform: macOS + Linux)
  # rtk >= 0.38 is REQUIRED: that's when `rtk hook claude` (the hook command the
  # init + doctor logic below expect) was introduced. An older binary already on
  # PATH (e.g. 0.31, which writes a different hook form) must be UPGRADED, not
  # just skipped — otherwise `rtk init -g` keeps installing the old hook form and
  # the doctor RTK-hook check WARNs forever. rtk has no self-update subcommand,
  # so re-running the upstream install.sh is the upgrade path.
  RTK_BIN="$HOME/.local/bin/rtk"
  RTK_MIN_VERSION="0.38.0"
  # Returns 0 if "$1" >= RTK_MIN_VERSION (sort -V: lowest of {min,ver} == min ⇒ ver>=min).
  rtk_version_ok() {
    local ver="$1"
    [ -n "$ver" ] || return 1
    [ "$(printf '%s\n%s\n' "$RTK_MIN_VERSION" "$ver" | sort -V | head -1)" = "$RTK_MIN_VERSION" ]
  }
  rtk_install_upstream() {
    run_with_timeout "RTK install" \
      "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh | sh" \
      | tail -3 || true
    export PATH="$HOME/.local/bin:$PATH"
  }
  if [ -x "$RTK_BIN" ]; then
    _rtk_cur="$("$RTK_BIN" --version 2>/dev/null | awk '{print $2}')"
    if rtk_version_ok "$_rtk_cur"; then
      log_and_print "    [OK] RTK $_rtk_cur (>= $RTK_MIN_VERSION)"
    else
      log_and_print "    RTK ${_rtk_cur:-unknown} < $RTK_MIN_VERSION — upgrading (need 'rtk hook claude' form)..."
      rtk_install_upstream
      _rtk_new="$(rtk --version 2>/dev/null | awk '{print $2}')"
      if rtk_version_ok "$_rtk_new"; then
        log_and_print "    [OK] RTK upgraded: $_rtk_new"
      else
        log_and_print "    [WARN] RTK still ${_rtk_new:-unknown} after upgrade (need >= $RTK_MIN_VERSION). See https://github.com/rtk-ai/rtk"
      fi
    fi
  else
    log_and_print "    Installing RTK..."
    rtk_install_upstream
    if command -v rtk &>/dev/null; then
      log_and_print "    [OK] RTK installed: $(rtk --version 2>/dev/null)"
    else
      log_and_print "    [WARN] RTK install failed. See https://github.com/rtk-ai/rtk"
    fi
  fi
  # RTK hook integrity.
  # rtk >= 0.38 registers the hook by writing
  #   PreToolUse[Bash] -> { "command": "rtk hook claude" }
  # directly into settings.json via `rtk init -g`. There is no longer a
  # separate `rtk-rewrite.sh` shell script. (Older setup.sh wired a custom
  # script path; that whole branch is obsolete in rtk 0.38+.)
  if command -v rtk &>/dev/null; then
    run_with_timeout "RTK init -g" "rtk init -g --auto-patch < /dev/null" | tail -3 || true
    if command -v python3 &>/dev/null; then
      python3 - "$CONFIG_DIR/settings.json" << 'PYEOF' | sed 's/^/    /'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    print("[WARN] settings.json missing — RTK hook check skipped")
    sys.exit(0)
try:
    data = json.loads(p.read_text())
except Exception as e:
    print(f"[WARN] settings.json unparseable ({e})")
    sys.exit(0)
pre = data.get("hooks", {}).get("PreToolUse", [])
wired = any(
    isinstance(e, dict) and e.get("matcher") == "Bash" and any(
        isinstance(h, dict) and h.get("command", "").startswith("rtk hook claude")
        for h in e.get("hooks", [])
    ) for e in pre
)
print("[OK] RTK hook wired (rtk hook claude)" if wired
      else "[WARN] RTK hook not in settings.json — run `rtk init -g` manually")
PYEOF
    fi
  fi
  # RTK for Codex + Gemini (Claude RTK hook wired above)
  if [ -x "$RTK_BIN" ]; then
    run_with_timeout "RTK init Codex" "$RTK_BIN init -g --codex < /dev/null" | tail -1 || true
    run_with_timeout "RTK init Gemini" "$RTK_BIN init -g --gemini --auto-patch < /dev/null" | tail -1 || true
    # `rtk init --gemini` overwrites ~/.gemini/GEMINI.md wholesale with RTK guidance
    # (Gemini has no @-include, so RTK replaces the file instead of appending a ref).
    # This clobbers the Layer A+B assembly from [4b], leaving GEMINI.md ~29 lines.
    # RTK usage notes already live in runtimes/<cli>/tools.md (Layer B), so re-assemble
    # to restore the full file. The RTK *hook* lives in settings.json — assembly never
    # touches it, so the token-rewrite hook stays wired.
    log_and_print "    Re-assembling global rules (rtk init --gemini clobbers GEMINI.md)..."
    assemble_global_rules
  fi
  # Graphify — package name is graphifyy; CLI command is graphify.
  # The graphify CLI is the source of truth for ~/.claude/skills/graphify/SKILL.md
  # (each machine's graphifyy version differs — repo-level SKILL.md would drift).
  export PATH="$HOME/.local/bin:$PATH"
  if command -v graphify &>/dev/null; then
    log_and_print "    [OK] Graphify CLI installed ($(command -v graphify))"
  elif command -v uv &>/dev/null; then
    log_and_print "    Installing Graphify (uv tool install graphifyy)..."
    run_with_timeout "Graphify install (uv)" "uv tool install graphifyy < /dev/null" \
      | tail -2 || true
    if command -v graphify &>/dev/null; then
      log_and_print "    [OK] Graphify installed: $(command -v graphify)"
    else
      log_and_print "    [WARN] Graphify install via uv failed — see $LOG_FILE"
    fi
  else
    log_and_print "    [WARN] Graphify missing. Install uv first, then run: uv tool install graphifyy"
  fi
  # Sync the Claude skill from the freshly installed graphify, so the SKILL.md
  # always matches the graphifyy package version on this machine (fixes the
  # "skill 0.5.2 vs package 0.8.11" mismatch warning that fires on every call).
  if command -v graphify &>/dev/null; then
    run_with_timeout "graphify install (claude)" "graphify install --platform claude < /dev/null" \
      | sed 's/^/    /' || true
    # Mirror into ~/.agents/skills so codex/gemini see the same SKILL via their
    # shared agents-skills scan. Replace any prior oh-my-agent-env symlink.
    if [ -d "$HOME/.claude/skills/graphify" ]; then
      mkdir -p "$AGENTS_DIR/skills"
      if [ -L "$AGENTS_DIR/skills/graphify" ] || [ -e "$AGENTS_DIR/skills/graphify" ]; then
        rm -rf "$AGENTS_DIR/skills/graphify"
      fi
      ln -s "$HOME/.claude/skills/graphify" "$AGENTS_DIR/skills/graphify"
      log_and_print "    [OK] graphify mirrored to $AGENTS_DIR/skills/graphify"
    fi
  fi
  # code-review-graph (CRG) — required by triangle-review + codebase-scan
  # CRG requires Python >=3.10. Use `uv tool install` for isolated env that works
  # regardless of system Python version. Fall back to pip3 only when uv missing.
  if command -v code-review-graph &>/dev/null; then
    log_and_print "    [OK] CRG $(code-review-graph --version 2>&1 | head -1)"
  elif command -v uv &>/dev/null; then
    log_and_print "    Installing code-review-graph (uv tool)..."
    run_with_timeout "CRG install (uv)" "uv tool install code-review-graph < /dev/null" \
      | tail -2 || true
    if command -v code-review-graph &>/dev/null; then
      log_and_print "    [OK] CRG installed: $(code-review-graph --version 2>&1 | head -1)"
    else
      log_and_print "    [WARN] CRG install via uv failed — see $LOG_FILE"
    fi
  else
    log_and_print "    [WARN] CRG missing. Install uv first, or pip3 install --user code-review-graph (Python>=3.10)"
  fi

  # codegraph — used by codebase-scan skill for symbol-level queries via MCP.
  # Node-based; install through npm into the user-owned prefix that
  # ensure_user_npm_prefix established at the top of doctor/sync.
  if command -v codegraph &>/dev/null; then
    log_and_print "    [OK] codegraph $(codegraph --version 2>&1 | head -1)"
  elif command -v npm &>/dev/null; then
    log_and_print "    Installing codegraph (npm -g)..."
    run_with_timeout "codegraph install (npm)" "npm i -g @colbymchenry/codegraph < /dev/null" \
      | tail -2 || true
    if command -v codegraph &>/dev/null; then
      log_and_print "    [OK] codegraph installed: $(codegraph --version 2>&1 | head -1)"
    else
      log_and_print "    [WARN] codegraph install via npm failed — see $LOG_FILE"
    fi
  else
    log_and_print "    [WARN] codegraph missing. Install Node.js + npm, then: npm i -g @colbymchenry/codegraph"
  fi
}
