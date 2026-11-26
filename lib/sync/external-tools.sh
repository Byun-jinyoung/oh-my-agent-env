# oh-my-agent-env: sync domain - external-tools.sh
# Sourced by lib/sync.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

# [7] External tools (context-mode, codex CLI, LazyCodex, codex-gemini-mcp fork)
sync_external_tools() {
  # External tools
  log_and_print "[7] External tools"
  # context-mode (Codex MCP + hooks)
  if command -v context-mode &>/dev/null; then
    log_and_print "    [OK] context-mode installed"
  else
    log_and_print "    Installing context-mode (npm global → $USER_NPM_PREFIX)..."
    run_with_timeout "context-mode install" "$NPM_USER_ENV npm install -g context-mode < /dev/null" \
      | tail -3 || true
    # Verify post-install (install may succeed but bin dir may not be on PATH).
    if command -v context-mode &>/dev/null; then
      log_and_print "    [OK] context-mode installed -> $(command -v context-mode)"
    else
      log_and_print "    [WARN] context-mode still not on PATH after install."
      log_and_print "           Run: echo 'export PATH=\"\$(npm config get prefix)/bin:\$PATH\"' >> ~/.bashrc"
    fi
  fi
  # graft (@nanonets/graft) — code graph that replaces grep/read in the
  # exploration phase: `graft ask/grep/skeleton/callers/map` cost ~1/10 the
  # tokens of raw search and self-refresh the structural graph (~3ms, $0, no key)
  # before every query, so answers reflect uncommitted edits. Uptake is wired
  # through hooks, not MCP: global graft hooks for Claude/Codex (sync_graft_hooks
  # in agent-clis.sh) and the GJC graft-nudge pre-hook (sync_gjc_hooks). The
  # tree-sitter grammars carry
  # native bindings whose npm install scripts are gated on npm 11, so allow them
  # explicitly (prebuilds cover any grammar not on the list — the script is
  # skipped, not fatal).
  if command -v graft &>/dev/null; then
    log_and_print "    [OK] graft installed -> $(command -v graft)"
  else
    log_and_print "    Installing graft (npm global → $USER_NPM_PREFIX)..."
    run_with_timeout "graft install" \
      "$NPM_USER_ENV npm install -g --allow-scripts=@nanonets/graft,tree-sitter,tree-sitter-go,tree-sitter-java,tree-sitter-kotlin,tree-sitter-php,tree-sitter-python,@davisvaughan/tree-sitter-r,tree-sitter-swift,tree-sitter-typescript,tree-sitter-cli,tree-sitter-javascript @nanonets/graft < /dev/null" \
      | tail -3 || true
    if command -v graft &>/dev/null; then
      log_and_print "    [OK] graft installed -> $(command -v graft)"
    else
      log_and_print "    [WARN] graft still not on PATH after install — graft hooks + CLI exploration will be unavailable."
      log_and_print "           Run: echo 'export PATH=\"\$(npm config get prefix)/bin:\$PATH\"' >> ~/.bashrc"
    fi
  fi
  # cc-alchemy-statusline — usage tracker that powers the 5h/wk bars + reset
  # countdown in ui/statusline/my-statusline.mjs. my-statusline shells out to
  # `cc-alchemy-statusline --fetch-only` to keep the rate-limit cache fresh;
  # without it the reset countdowns go stale (show no "(…)"). npm global pkg.
  if command -v cc-alchemy-statusline &>/dev/null; then
    log_and_print "    [OK] cc-alchemy-statusline installed"
  else
    log_and_print "    Installing cc-alchemy-statusline (npm global → $USER_NPM_PREFIX)..."
    run_with_timeout "cc-alchemy-statusline install" "$NPM_USER_ENV npm install -g cc-alchemy-statusline < /dev/null" \
      | tail -3 || true
    if command -v cc-alchemy-statusline &>/dev/null; then
      log_and_print "    [OK] cc-alchemy-statusline installed -> $(command -v cc-alchemy-statusline)"
    else
      log_and_print "    [WARN] cc-alchemy-statusline still not on PATH after install — statusline reset countdown will be stale."
    fi
  fi
  # open-code-review (`ocr`) — alibaba's deterministic-pipeline code reviewer.
  # Surveyed 2026-08-07 and rated "conditional" (manual CLI; automatic only
  # when wired into CI); the operator chose to install it anyway on 2026-08-16.
  # Package name verified against the upstream README (line 108) and the npm
  # registry: repository.url = github.com/alibaba/open-code-review, v1.9.4.
  # The Claude/Codex plugins that expose /ocr slash commands are registered in
  # sync_plugins_mcp; this is only the binary they shell out to.
  if command -v ocr &>/dev/null; then
    log_and_print "    [OK] open-code-review (ocr) installed"
  else
    log_and_print "    Installing open-code-review (npm global → $USER_NPM_PREFIX)..."
    run_with_timeout "open-code-review install" "$NPM_USER_ENV npm install -g @alibaba-group/open-code-review < /dev/null" \
      | tail -3 || true
    if command -v ocr &>/dev/null; then
      log_and_print "    [OK] open-code-review installed -> $(command -v ocr)"
    else
      log_and_print "    [WARN] ocr still not on PATH after install — /ocr plugin commands will fail to spawn it."
    fi
  fi
  # semantica — typed context graph + provenance (semantica-agi/semantica, the
  # enterprise KG the operator confirmed on 2026-08-07, not the 17-star AST
  # search of the same name). Installed as a uv tool like serena so it lands
  # in ~/.local/bin without touching the system Python; ships `semantica-mcp`,
  # which sync_plugins_mcp registers at user scope.
  if command -v semantica-mcp &>/dev/null; then
    log_and_print "    [OK] semantica installed"
  elif command -v uv &>/dev/null; then
    log_and_print "    Installing semantica (uv tool install semantica → ~/.local/bin)..."
    run_with_timeout "semantica install" "uv tool install semantica < /dev/null" | tail -3 || true
    if command -v semantica-mcp &>/dev/null; then
      log_and_print "    [OK] semantica installed -> $(command -v semantica-mcp)"
    else
      log_and_print "    [WARN] semantica-mcp still not on PATH after install — MCP registration below will point at a missing binary."
    fi
  else
    log_and_print "    [SKIP] semantica — uv not found (install uv, then re-run sync)"
  fi
  # Codex CLI — REQUIRED by codex-mcp (the MCP spawns `codex` from PATH).
  # One install on every machine: the official standalone installer (see
  # CODEX_INSTALL_CMD in lib/common.sh); `oms update --tools` keeps it current.
  # Other copies (npm, Homebrew, old wrappers) are reported, never removed —
  # PATH order would otherwise decide which codex runs.
  if codex_standalone; then
    log_and_print "    [OK] codex CLI (standalone) -> $HOME/.local/bin/codex"
  else
    log_and_print "    Installing codex CLI with the official installer ($CODEX_INSTALL_CMD)..."
    # NON_INTERACTIVE: no prompts, and the installer leaves other installs in place.
    run_with_timeout "codex standalone install" \
      "set -o pipefail; curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh < /dev/null" \
      | tail -3 || true
    hash -r
    if codex_standalone; then
      log_and_print "    [OK] codex CLI installed -> $HOME/.local/bin/codex"
    else
      log_and_print "    [WARN] codex standalone install failed — codex-mcp will not function. See $LOG_FILE; manual: $CODEX_INSTALL_CMD"
    fi
  fi
  local _codex_dups _codex_p _codex_cmd
  _codex_dups="$(codex_duplicates)"
  if [ -n "$_codex_dups" ]; then
    log_and_print "    [codex] [WARN] other codex installs besides $HOME/.local/bin/codex — remove them:"
    while IFS="$(printf '\t')" read -r _codex_p _codex_cmd; do
      log_and_print "             • $_codex_p  →  $_codex_cmd"
    done <<EOF
$_codex_dups
EOF
  fi

  # LazyCodex — Codex agent harness installed via npx. The public package is
  # lazycodex-ai, but the Codex plugin it registers is omo@sisyphuslabs.
  if verify_lazycodex_codex_plugin; then
    local _lcx_version=""
    _lcx_version="$(find "$CODEX_DIR/plugins/cache/sisyphuslabs/omo" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1 | xargs basename 2>/dev/null || true)"
    log_and_print "    [OK] LazyCodex installed as omo@sisyphuslabs${_lcx_version:+ ($_lcx_version)}"
  elif command -v npm &>/dev/null && command -v codex &>/dev/null; then
    log_and_print "    Installing LazyCodex for Codex (npx lazycodex-ai@latest install --no-tui)..."
    run_with_timeout "LazyCodex install" \
      "$NPM_USER_ENV npx --yes lazycodex-ai@latest install --no-tui < /dev/null" \
      | tail -4 || true
    if verify_lazycodex_codex_plugin; then
      local _lcx_version=""
      _lcx_version="$(find "$CODEX_DIR/plugins/cache/sisyphuslabs/omo" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1 | xargs basename 2>/dev/null || true)"
      log_and_print "    [OK] LazyCodex installed as omo@sisyphuslabs${_lcx_version:+ ($_lcx_version)}"
      log_and_print "         Restart Codex App/CLI and approve omo@sisyphuslabs hooks on first launch."
    else
      log_and_print "    [WARN] LazyCodex install ran but Codex plugin verification failed — see $LOG_FILE"
      log_and_print "           Manual check: codex plugin list | grep 'omo@sisyphuslabs'"
    fi
  else
    log_and_print "    [SKIP] LazyCodex — requires npm and codex CLI"
  fi

  # codex-gemini-mcp (Byun-jinyoung fork — codex-mcp + antigravity-mcp)
  # The fork shares the npm package name @donghae0414/codex-gemini-mcp with
  # upstream donghae0414, so upstream installs win on PATH unless explicitly
  # uninstalled first. We always run cleanup before (re)install to guarantee
  # the fork is what ends up on disk.
  if verify_codex_gemini_mcp; then
    log_and_print "    [OK] codex-mcp + antigravity-mcp (Byun-jinyoung fork verified)"
  else
    log_and_print "    Cleaning up upstream donghae0414 install (if any)..."
    cleanup_upstream_codex_gemini_mcp
    log_and_print "    Installing/repairing Byun-jinyoung fork (target: $USER_NPM_PREFIX)..."
    # Pass npm_config_prefix into the piped bash so the fork's install.sh
    # (which calls `npm install -g ./<tarball>`) writes into USER_NPM_PREFIX
    # on its FIRST attempt — that skips its sudo-fallback branch entirely
    # and keeps the package inside MY $HOME (mode 0700 via ensure_user_npm_prefix)
    # instead of /usr/local|/opt|/usr where other users on a shared host could
    # read provider configs, model defaults, or any embedded data.
    # `npm prefix -g` inside install.sh also reads this env var, so its
    # post-install path resolution lines up with the actual install location.
    # `set -o pipefail` and curl's `-f` are both load-bearing. Without -f, curl
    # exits 0 on a 404 and pipes the error page into bash; without pipefail,
    # bash's own 0 masks a curl that failed outright. Either way the install
    # "succeeds" having done nothing, and the WARN below then blames PATH
    # shadowing for what was really a download that never happened.
    local install_out install_rc=0
    install_out="$(run_with_timeout "codex-gemini-mcp install" \
      "set -o pipefail; $NPM_USER_ENV curl -fsSL https://raw.githubusercontent.com/Byun-jinyoung/codex-gemini-mcp/main/install.sh | $NPM_USER_ENV bash")" \
      || install_rc=$?
    [ -n "$install_out" ] && printf '%s\n' "$install_out" | tail -3
    if verify_codex_gemini_mcp; then
      log_and_print "    [OK] Byun-jinyoung fork installed and verified"
    elif [ "$install_rc" -ne 0 ]; then
      log_and_print "    [WARN] fork install command itself failed (exit=$install_rc) — see $LOG_FILE"
      log_and_print "           Check network access to raw.githubusercontent.com before suspecting PATH."
    else
      log_and_print "    [WARN] fork install ran but integrity still failing — see $LOG_FILE"
      log_and_print "           Most likely cause: system-wide /usr/bin/{codex,gemini}-mcp symlinks shadowing fork on PATH"
      log_and_print "           Resolve sudo warnings above, then re-run 'setup.sh sync'."
    fi
  fi
  # gemini-swarm install logic removed 2026-05-25: Gemini CLI is fully deprecated
  # in favor of Antigravity (agy). runtimes/claude/commands/gemini-swarm.md
  # already carries a DEPRECATED notice for the orchestration command.
}
