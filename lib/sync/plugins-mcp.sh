# oh-my-agent-env: sync domain - plugins-mcp.sh
# Sourced by lib/sync.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

# What is registered at USER scope for $1, read from the registry file.
#
# Not `claude mcp get`: with a project-scope .mcp.json in cwd (oma generates one,
# and it names serena), `claude mcp get serena` answers about the PROJECT entry
# and prints no Command:/Args: lines at all — so a user-scope command drift is
# invisible to it. Verified on this machine.
#
# $2 selects the view:
#   cmdline -> command, then each arg, one per line
#   env     -> KEY=VALUE per line, PATH excluded (its own check owns it)
#   path    -> env.PATH alone
# Prints nothing when the name is absent or carries no command (the http/sse
# transports), which every caller reads as "nothing to compare".
#
# Top-level rather than nested inside sync_plugins_mcp so the smoke test can
# source this file and call it without running a sync.
mcp_user_field() {
  command -v python3 &>/dev/null || return 0
  python3 - "$HOME/.claude.json" "$1" "$2" 2>/dev/null <<'PYEOF'
import json, sys

path, name, what = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    servers = json.load(open(path)).get("mcpServers") or {}
except (OSError, ValueError):
    raise SystemExit(0)
entry = servers.get(name)
if not isinstance(entry, dict) or not entry.get("command"):
    raise SystemExit(0)
env = entry.get("env") or {}
if what == "cmdline":
    print("\n".join([entry["command"], *(str(a) for a in entry.get("args") or [])]))
elif what == "path":
    if env.get("PATH"):
        print(env["PATH"])
else:
    for k, v in env.items():
        if k != "PATH":
            print(f"{k}={v}")
PYEOF
}

# Does the user-scope registration for $1 disagree with the program $2 asks for?
# Exit 0 means drift; the two sides are then in MCP_DRIFT_HAVE / MCP_DRIFT_WANT
# for the caller to log.
#
# A name appearing in `claude mcp list` only proves SOMETHING owns that name.
# add_mcp compared env and never the command, so a registration pointing at the
# wrong program survived every sync. Not hypothetical: serena was registered as
# `uvx --from git+…` (upstream HEAD) while setup.sh installs the pinned release
# and oma's .mcp.json runs `serena` off PATH. Two builds sharing one
# .serena/project.yml, and their config schemas disagree — HEAD writes
# `language_servers:`, the release reads `languages:` and raises KeyError before
# the handshake. sync could not heal it because sync could not see it.
#
# Only the stdio form we generate is comparable (`… -- <cmd> [args…]`); the
# http/sse registrations have no `--` and are reported as no drift. xargs does
# the tokenizing so a quoted argument splits the way the shell would rather than
# by naive word splitting. An empty read means the name is not at user scope at
# all — someone else's project entry — and we make no claim about it.
MCP_DRIFT_HAVE=""
MCP_DRIFT_WANT=""
mcp_cmdline_drift() {
  local name="$1" cmd="$2" have want
  MCP_DRIFT_HAVE=""; MCP_DRIFT_WANT=""
  [[ "$cmd" == *" -- "* ]] || return 1
  have="$(mcp_user_field "$name" cmdline | tr '\n' ' ')"
  want="$(printf '%s' "${cmd#* -- }" | xargs -n1 2>/dev/null | tr '\n' ' ')"
  [ -n "$have" ] && [ -n "$want" ] || return 1
  MCP_DRIFT_HAVE="${have% }"
  MCP_DRIFT_WANT="${want% }"
  [ "$MCP_DRIFT_HAVE" != "$MCP_DRIFT_WANT" ]
}

# [8][9] Claude Code plugins + MCP servers (incl. local helpers install_plugin/add_mcp/migrate)
sync_plugins_mcp() {
  # [8] Claude Code plugins
  log_and_print "[8] Plugins"
  if command -v claude &>/dev/null; then
    log_and_print "    Fetching plugin list..."
    local plugin_list
    plugin_list=$(maybe_timeout 30 claude plugin list < /dev/null 2>&1) || {
      log_and_print "    [WARN] claude plugin list failed (timeout or error), skipping"
      plugin_list=""
    }
    [ -n "$plugin_list" ] && log_and_print "    Plugin list retrieved."

    install_plugin() {
      local name="$1" match="$2" marketplace="$3" pkg="$4"
      log_and_print "    [$name] checking..."
      if [ -n "$plugin_list" ] && echo "$plugin_list" | grep -q "$match"; then
        log_and_print "    [$name] OK — already installed"
      elif [ -z "$plugin_list" ]; then
        log_and_print "    [$name] SKIP — plugin list unavailable"
      else
        if [ -n "$marketplace" ]; then
          log_and_print "    [$name] marketplace add..."
          run_with_timeout "$name marketplace add" "claude plugin marketplace add $marketplace < /dev/null" | tail -1 || true
        fi
        log_and_print "    [$name] installing..."
        run_with_timeout "$name install" "claude plugin install $pkg < /dev/null" | tail -1 || true
      fi
    }

    install_plugin "octo" "octo@nyldn" "https://github.com/nyldn/claude-octopus.git" "octo@nyldn-plugins"
    install_plugin "claude-mem" "claude-mem@thedotmack" "thedotmack/claude-mem" "claude-mem@thedotmack"
    install_plugin "ouroboros" "ouroboros@ouroboros" "Q00/ouroboros" "ouroboros@ouroboros"
    install_plugin "document-skills" "document-skills@anthropic" "anthropics/skills" "document-skills@anthropic-agent-skills"
    install_plugin "context-mode" "context-mode@context-mode" "mksglu/context-mode" "context-mode@context-mode"
    # OpenAI official: /codex:review, /codex:adversarial-review, /codex:rescue, etc.
    # Uses the global `codex` CLI + ~/.codex/config.toml. Coexists with codex-mcp.
    install_plugin "codex-plugin-cc" "codex@openai-codex" "openai/codex-plugin-cc" "codex@openai-codex"
  else
    log_and_print "    [SKIP] Claude Code not found"
  fi

  # [9] MCP servers
  log_and_print "[9] MCP servers"
  if command -v claude &>/dev/null; then
    log_and_print "    Fetching MCP list..."
    local mcp_list
    mcp_list=$(maybe_timeout 30 claude mcp list < /dev/null 2>&1) || {
      log_and_print "    [WARN] claude mcp list failed (timeout or error), skipping"
      mcp_list=""
    }
    [ -n "$mcp_list" ] && log_and_print "    MCP list retrieved."

    # Auto-migrate a local-scope MCP entry at the current cwd to user scope.
    # Uses JSON-level access (claude mcp add-json + ~/.claude.json identity
    # check) rather than text scraping + eval — that earlier approach was
    # unsafe (shell injection, args-with-spaces loss, multiline env loss).
    # Aborts on conflict (user already has different payload) and preserves
    # the local entry on any failure.
    migrate_mcp_local_to_user() {
      local name="$1"
      python3 - "$name" "$HOME/.claude.json" "$PWD" << 'PYEOF'
import json, sys, subprocess, os
name, path, cwd = sys.argv[1], sys.argv[2], sys.argv[3]

def warn(msg):
    print(f"    [{name}] [WARN] {msg}")

try:
    data = json.load(open(path))
except (OSError, json.JSONDecodeError) as e:
    warn(f"~/.claude.json unreadable ({e}) — skipping migration")
    sys.exit(1)

projects = data.get('projects') or {}
# Path-key candidates: claude may key projects by raw cwd, realpath, or normpath
candidates = {cwd, os.path.realpath(cwd), os.path.normpath(cwd)}
matches = [k for k in candidates if name in ((projects.get(k) or {}).get('mcpServers') or {})]
if not matches:
    sys.exit(0)
if len(set(matches)) > 1:
    warn(f"ambiguous project key match ({matches}) — manual review needed")
    sys.exit(1)
local_entry = projects[matches[0]]['mcpServers'][name]

user_entry = (data.get('mcpServers') or {}).get(name)
if user_entry is not None and user_entry != local_entry:
    warn("user-scope entry differs from local — local preserved (manual review needed)")
    sys.exit(1)

if user_entry is None:
    proc = subprocess.run(
        ['claude', 'mcp', 'add-json', '--scope', 'user', name, json.dumps(local_entry)],
        capture_output=True, text=True
    )
    if proc.returncode != 0:
        warn(f"add-json failed (rc={proc.returncode}): {(proc.stderr or '').strip()[:200]}")
        sys.exit(1)
    try:
        data2 = json.load(open(path))
    except (OSError, json.JSONDecodeError) as e:
        warn(f"~/.claude.json reread failed ({e}) — local preserved")
        sys.exit(1)
    if (data2.get('mcpServers') or {}).get(name) != local_entry:
        warn("user-scope copy not equal to local after add — local preserved")
        sys.exit(1)

rm = subprocess.run(
    ['claude', 'mcp', 'remove', name, '-s', 'local'],
    capture_output=True, text=True
)
if rm.returncode != 0:
    warn(f"local remove failed: {(rm.stderr or '').strip()[:200]} — duplicate state, manual cleanup needed")
    sys.exit(1)

print(f"    [{name}] [OK] migrated local -> user scope")
PYEOF
    }

    # Register an MCP server with claude. If already registered, also verify
    # that any baked-in env (currently just PATH, which we inject for codex-mcp
    # and antigravity-mcp) matches what `cmd` asks for. If it drifted (the
    # entry was registered by an older setup.sh that didn't inject PATH, or
    # USER_NPM_PREFIX changed across machines), tear down and re-register so
    # the new env takes effect. Without this, a once-registered entry stays
    # frozen forever and `setup.sh sync` cannot heal a broken machine.
    add_mcp() {
      local name="$1" cmd="$2" binary="$3"
      log_and_print "    [$name] checking..."

      local needs_register=0
      if echo "$mcp_list" | grep -q "$name"; then
        # Already registered — but `mcp_list` spans every scope, so that name may
        # belong to a project .mcp.json we do not own. Only an entry we hold at
        # user scope is ours to compare against, and an absent one must not read
        # as "every env key is missing".
        local expected_path="" current_env="" current_path="" _at_user
        _at_user="$(mcp_user_field "$name" cmdline)"
        if [ -n "$_at_user" ] && [[ "$cmd" == *"-e PATH="* ]]; then
          # Extract PATH=<value> token from the cmd string (value runs up to
          # next whitespace; we never quote PATH in our generated cmd lines).
          expected_path="$(echo "$cmd" | sed -nE 's/.*-e PATH=([^[:space:]]+).*/\1/p')"
        fi
        if [ -n "$expected_path" ]; then
          # From the registry, not `claude mcp get`. With a project .mcp.json in
          # cwd that names this server, `claude mcp get` answers about the
          # PROJECT entry and prints no env lines at all — so current_path came
          # back empty on every run, the comparison never matched, and serena was
          # torn down and re-registered on every single sync. Measured here:
          # `claude mcp get serena` reports "Scope: Project config" and nothing
          # else, while the user entry carried the correct baked PATH all along.
          current_path="$(mcp_user_field "$name" path)"
          if [ "$current_path" != "$expected_path" ]; then
            log_and_print "    [$name] env PATH out of date — re-registering"
            log_and_print "             have: ${current_path:-<unset>}"
            log_and_print "             want: $expected_path"
            # Preserve any user-added env vars (anything except PATH, which we
            # re-inject below). Without this, ad-hoc keys in ~/.claude.json
            # (e.g. MCP_CODEX_DEFAULT_MODEL) get silently dropped whenever a
            # PATH drift triggers re-register.
            local _preserve_args="" _eline _ek _ev
            while IFS= read -r _eline; do
              [ -z "$_eline" ] && continue
              _ek="${_eline%%=*}"
              _ev="${_eline#*=}"
              case "$_ek" in PATH|"") continue ;; esac
              _preserve_args+=" -e ${_ek}=${_ev}"
              log_and_print "    [$name] preserving env: ${_ek}"
            done < <(mcp_user_field "$name" env)
            if [ -n "$_preserve_args" ]; then
              # Inject preserved -e flags just before `-- <binary>` in cmd
              cmd="${cmd/ -- /${_preserve_args} -- }"
            fi
            maybe_timeout 10 claude mcp remove "$name" -s user </dev/null 2>&1 | sed 's/^/      /' || true
            # Also clear any local-scope shadow that would resurface
            maybe_timeout 10 claude mcp remove "$name" -s local </dev/null 2>&1 | sed 's/^/      /' || true
            needs_register=1
          fi
        fi
        # Generic env drift check beyond PATH: extract every `-e KEY=VAL`
        # token from cmd and compare against the live entry. Catches the
        # case where new env keys (e.g. MCP_CODEX_DEFAULT_MODEL) were added
        # in a later setup.sh version but an older registration lacks them.
        # Without this, just adding -e flags to cmd would do nothing for
        # machines that already had codex-mcp registered.
        if [ "$needs_register" = "0" ] && [ -n "$_at_user" ]; then
          current_env="$(mcp_user_field "$name" env)"
          local _exp_line _ek _ev _cur_v
          while IFS= read -r _exp_line; do
            [ -z "$_exp_line" ] && continue
            _ek="${_exp_line%%=*}"
            _ev="${_exp_line#*=}"
            # PATH already covered above; skip to avoid duplicate work.
            case "$_ek" in PATH|"") continue ;; esac
            _cur_v="$(printf '%s\n' "$current_env" | sed -n "s/^${_ek}=//p" | head -1)"
            if [ "$_cur_v" != "$_ev" ]; then
              log_and_print "    [$name] env $_ek out of date — re-registering"
              log_and_print "             have: ${_cur_v:-<unset>}"
              log_and_print "             want: $_ev"
              maybe_timeout 10 claude mcp remove "$name" -s user </dev/null 2>&1 | sed 's/^/      /' || true
              maybe_timeout 10 claude mcp remove "$name" -s local </dev/null 2>&1 | sed 's/^/      /' || true
              needs_register=1
              break
            fi
          done < <(echo "$cmd" | grep -oE '\-e [A-Z_][A-Z0-9_]*=[^[:space:]]+' | sed -E 's/^-e ([A-Z_][A-Z0-9_]*)=(.*)$/\1=\2/')
        fi
        if [ "$needs_register" = "0" ] && mcp_cmdline_drift "$name" "$cmd"; then
          log_and_print "    [$name] command out of date — re-registering"
          log_and_print "             have: $MCP_DRIFT_HAVE"
          log_and_print "             want: $MCP_DRIFT_WANT"
          # Same env-preservation contract as the PATH branch, minus its
          # duplicate-flag hazard: a key the canonical cmd already sets is
          # skipped, so re-registering cannot resurrect a stale value by
          # appending it after our own.
          local _preserve="" _kv
          while IFS= read -r _kv; do
            [ -n "$_kv" ] || continue
            case " $cmd " in *" -e ${_kv%%=*}="*) continue ;; esac
            _preserve+=" -e ${_kv}"
            log_and_print "    [$name] preserving env: ${_kv%%=*}"
          done < <(mcp_user_field "$name" env)
          if [ -n "$_preserve" ]; then
            cmd="${cmd/ -- /${_preserve} -- }"
          fi
          maybe_timeout 10 claude mcp remove "$name" -s user </dev/null 2>&1 | sed 's/^/      /' || true
          maybe_timeout 10 claude mcp remove "$name" -s local </dev/null 2>&1 | sed 's/^/      /' || true
          needs_register=1
        fi
        if [ "$needs_register" = "0" ]; then
          log_and_print "    [$name] OK — already registered"
          # Detect local-scope shadow and auto-migrate. Earlier setup.sh
          # defaulted to local scope; this preserves env/headers/args via
          # JSON identity.
          if maybe_timeout 10 claude mcp get "$name" </dev/null 2>/dev/null \
               | grep -q 'Scope: Local'; then
            migrate_mcp_local_to_user "$name"
          fi
        fi
      else
        needs_register=1
      fi

      if [ "$needs_register" = "1" ]; then
        if [ -n "$binary" ] && ! command -v "$binary" &>/dev/null; then
          log_and_print "    [$name] SKIP — $binary binary not found"
          return 0
        fi
        log_and_print "    [$name] registering..."
        # No capture: run_with_timeout already logs the failing output
        # (lib/common.sh "output: $output"), so holding it here only made
        # an unused variable.
        if run_with_timeout "$name mcp add" "$cmd < /dev/null" >/dev/null 2>&1; then
          log_and_print "    [$name] registered successfully (user scope)"
        else
          log_and_print "    [$name] registration failed — see $LOG_FILE"
        fi
      fi
    }

    # All MCPs registered at -s user (Claude default is local — was creating
    # cwd-bound entries that silently shadowed any user-level OAuth/auth state).
    # Stale gemini-mcp entry cleanup: the Byun-jinyoung fork renamed gemini → antigravity,
    # so any pre-existing gemini-mcp MCP entry points to a binary that no longer exists.
    # Remove from both scopes (user + local-at-cwd) before registering the new antigravity-mcp.
    if echo "$mcp_list" | grep -q '^gemini-mcp\b\|^gemini-mcp\s'; then
      log_and_print "    [gemini-mcp] removing stale entry (fork dropped gemini-mcp → antigravity-mcp)"
      maybe_timeout 10 claude mcp remove gemini-mcp -s user </dev/null 2>&1 | sed 's/^/      /' || true
      maybe_timeout 10 claude mcp remove gemini-mcp -s local </dev/null 2>&1 | sed 's/^/      /' || true
      # Refresh mcp_list so subsequent add_mcp grep checks see the removal
      mcp_list=$(maybe_timeout 30 claude mcp list < /dev/null 2>&1) || mcp_list=""
    fi

    # codex-mcp spawns the `codex` CLI from PATH at request time. Claude Code's
    # MCP child process inherits a minimal PATH that often lacks npm-global/bin,
    # so codex-mcp silently fails on machines where `codex` lives there (e.g.
    # @openai/codex installed via `npm i -g`). Inject a PATH that includes
    # npm-global/bin + standard system dirs at registration time so the value is
    # baked into ~/.claude.json and reused on every spawn.
    local NPM_BIN_DIR CODEX_PATH _codex_resolved _codex_dir
    NPM_BIN_DIR=""
    if _npm_prefix_q="$(npm config get prefix 2>/dev/null)" && [ -n "$_npm_prefix_q" ]; then
      NPM_BIN_DIR="${_npm_prefix_q}/bin"
    fi
    # Resolve actual codex location now so it can lead the baked-in PATH —
    # otherwise we hardcode npm/system order and a user's Volta/asdf/nvm shim
    # gets missed. USER_NPM_PREFIX/bin is where we install into in this script.
    _codex_resolved=""
    _codex_dir=""
    if command -v codex &>/dev/null; then
      _codex_resolved="$(command -v codex)"
      _codex_dir="$(dirname "$_codex_resolved")"
    fi
    # antigravity-mcp shells out to the `agy` CLI, which typically installs to
    # ~/.local/bin — a dir NOT covered by the npm/system segments below. Without
    # agy's dir in the baked PATH, antigravity-mcp starts (stdio handshake ok, so
    # doctor reports OK) but every antigravity call fails with `agy` ENOENT,
    # silently breaking triangle-review/debate-loop/analyze-paper. Resolve agy's
    # dir (and include ~/.local/bin generally) so the injected PATH can find it.
    local _agy_dir=""
    if command -v agy &>/dev/null; then _agy_dir="$(dirname "$(command -v agy)")"; fi
    # Build PATH from non-empty segments only (guard against empty npm prefix
    # turning into bare ":/usr/local/bin..." which means "current dir first").
    # Order: actual codex location → USER_NPM_PREFIX/bin → currently-configured
    # npm prefix bin → ~/.npm-global/bin → standard system dirs.
    CODEX_PATH=""
    for _seg in "$_codex_dir" \
                "$USER_NPM_PREFIX/bin" \
                "$NPM_BIN_DIR" \
                "$HOME/.npm-global/bin" \
                "$_agy_dir" \
                "$HOME/.local/bin" \
                "/usr/local/bin" "/opt/homebrew/bin" "/usr/bin" "/bin"; do
      [ -n "$_seg" ] || continue
      # de-dup
      case ":$CODEX_PATH:" in *":$_seg:"*) continue ;; esac
      [ -z "$CODEX_PATH" ] && CODEX_PATH="$_seg" || CODEX_PATH="${CODEX_PATH}:${_seg}"
    done
    # If live PATH lookup missed it, probe each injected segment.
    if [ -z "$_codex_resolved" ]; then
      IFS=':' read -ra _segs <<<"$CODEX_PATH"
      for _seg in "${_segs[@]}"; do
        if [ -x "$_seg/codex" ]; then _codex_resolved="$_seg/codex"; break; fi
      done
    fi
    if [ -z "$_codex_resolved" ]; then
      log_and_print "    [codex-mcp] [WARN] \`codex\` CLI not findable. Install with: npm i -g @openai/codex"
    else
      log_and_print "    [codex-mcp] codex CLI resolved: $_codex_resolved"
    fi
    # Default codex model for the MCP. Fork hardcodes gpt-5.3-codex which is
    # not available on every ChatGPT plan (exit 1 on first call). Override via
    # MCP_CODEX_DEFAULT_MODEL env, which fork's dist/config.js getDefaultModel()
    # reads at request time. Allow per-machine override via CC_BOOTSTRAP_CODEX_MODEL.
    local CODEX_DEFAULT_MODEL="${CC_BOOTSTRAP_CODEX_MODEL:-gpt-5.5}"
    add_mcp "codex-mcp" \
      "claude mcp add -s user codex-mcp -e PATH=${CODEX_PATH} -e MCP_CODEX_DEFAULT_MODEL=${CODEX_DEFAULT_MODEL} -- codex-mcp" \
      "codex-mcp"
    add_mcp "antigravity-mcp" \
      "claude mcp add -s user antigravity-mcp -e PATH=${CODEX_PATH} -- antigravity-mcp" \
      "antigravity-mcp"
    # The release on PATH, not upstream HEAD. setup.sh cmd_oma [0] installs the
    # pinned release (`uv tool install serena-agent`) precisely because oma's
    # generated .mcp.json runs `command: serena` — see setup.sh:262 — so HEAD
    # registered here was a second, unpinned build of the same tool sharing one
    # .serena/project.yml with the first. Their config schemas have diverged
    # (HEAD: `language_servers:`, release: `languages:`, and RENAMED_FIELDS
    # carries no migration between them), so whichever wrote last locked the
    # other out with a KeyError. Also gains the `binary` guard: with no serena
    # installed this now SKIPs loudly instead of registering an entry that can
    # never start, which is the state doctor had to grow a reason message for.
    add_mcp "serena" \
      "claude mcp add -s user serena -e PATH=${CODEX_PATH} -- serena start-mcp-server --context claude-code --open-web-dashboard false" \
      "serena"
    add_mcp "supermemory" "claude mcp add -s user --transport http supermemory https://mcp.supermemory.ai/mcp" ""
  fi
}
