---
name: herdr-app
description: >
  Inspect and control terminals and agent sessions in herdr-app (the Herdr Mac
  app with the `hc` core CLI): list sessions, start a peer/sub-agent with
  `hc run`, read or send keys, give it a tab, and check the status the sidebar
  shows (working, idle, done, blocked: Needs you). Use when the user mentions
  Herdr, herdr-app, hc, a Herdr tab/space/sidebar, or asks to start, inspect or
  stop another agent session through Herdr. Do not start sessions merely
  because parallelism could help.
---

# herdr-app

Herdr is herdr-app (Mac GUI) plus the `hc` core CLI, which every machine has.
The old `herdr` 0.8 CLI is legacy: use it only when `HERDR_ENV=1` is set.

## First, always check (never answer "unavailable" before this)

```sh
command -v hc && hc ls --json          # live terminals: address, name, agent, status, parent
echo "${HC_TERMINAL_ID:-not in a herdr terminal}"   # this session's own address
command -v herdr-app && herdr-app status  # Mac only: app, layout, machines, errors
```

`HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, `HC_SCOPE` mark a herdr terminal.
`HERDR_ENV` is not set by herdr-app; its absence does not mean Herdr is missing.

## Sessions

```sh
hc run --bg --name <name> -- <command>    # child of this terminal (parent recorded)
hc get <addr>                             # one terminal, incl. status {state, kind, app}
hc keys <addr> <keys...>                  # send keys (e.g. `esc`, `enter`)
hc kill <addr> && hc rm <addr>            # stop, then remove the record
```

- `--name`: `a-z 0-9 - _`, 1-32 chars, unique among live terminals.
- Started from outside the main terminal: add `--parent <main addr>`. Never `--no-parent`
  for a peer. A child ends with its parent unless `--outlive-parent`.
- Remote machines (`hc run --on <machine>`) have `hc` only: no `herdr-app`.

## Tabs and the sidebar tree (Mac)

A peer must be (1) a child of main in the tree, (2) in its own tab, (3) shown once.
After starting peers, create their tabs on the Mac with:

```sh
herdr-keep-missing            # dry run
herdr-keep-missing --apply    # keep/move every parented sub-agent into its own tab
```

- Layout must be `my-layout` (the `my-agents` mod draws children only under the parent).
  Switch with `herdr-app do layout.switch '{"name":"my-layout"}'`, then
  `herdr-app do layout.show '{"id":"sidebar"}'`. Never hide the sidebar.
- `space.select` takes JSON only: `herdr-app do space.select '{"id":"<space id>"}'`.
- Never `terminal.park` while the goal is tree + tab: it removes the tab.
- The agent cannot see the sidebar; ask the user to confirm what it shows.

## Status reporting (what makes the sidebar right)

Agents report state with OSC 7501 after asking the terminal `OSC 7501;?`.

- agy-cli / claude / codex in a herdr terminal: native, nothing to do.
- Inside tmux (OMS panel main): tmux drops the query, so `herdr-tmux-osc` (tmux hooks
  in `~/.tmux.conf`) pipes each panel main pane, answers the query and relays the
  reports. It covers agents started after the pipe; restart an older agent.
- agy-app (Antigravity desktop): `agy-app-herdr` keeps a stand-in terminal named
  `agy-app` fed by agy hooks (`~/.gemini/config/hooks.json`, group `herdr-agy-app`).
  App tool-approval waits show as working (agy has no permission hook).

Check: `hc get <addr>` status, `herdr-app ls` (pane, space), `herdr-app status`.

## Managed files

All of the above is installed by oh-my-env `setup.sh sync` from
`runtimes/herdr-app/`; edit there, not in the installed copies.
