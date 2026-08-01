# oh-my-agent-env

One-command Claude Code environment setup for multiple machines.

## Quick Start

```bash
git clone https://github.com/Byun-jinyoung/oh-my-agent-env.git
cd oh-my-agent-env
bash setup.sh
```

## What It Installs

| Component | Description |
|---|---|
| **codex-gemini-mcp** (fork) | MCP servers `codex-mcp` + `antigravity-mcp` with multi-turn `session_id` resume (Gemini provider removed 2026-06-18) |
| **my-statusline.mjs** | Custom statusline (omc-free, OMC-style bars): `Model: \| branch: \| 5h/wk usage bars \| session \| ctx` — renders from the cc-alchemy usage cache + transcript |
| **GEMINI.md** | Global reliability rules for Antigravity (agy reads `~/.gemini/GEMINI.md` via gemini-cli inheritance) |
| **instructions.md** | Global reliability rules for Codex CLI |
| **LazyCodex** | Codex plugin `omo@sisyphuslabs` installed via `npx lazycodex-ai@latest install --no-tui` |
| **oh-my-agent (oma)** | Per-project multi-agent harness (first-fluke/oh-my-agent), installed via `setup.sh oma <path>` |
| **Graphify** | Knowledge graph CLI (`graphifyy` package, `graphify` command), Claude/Codex skills, and project hooks |

## Directory Structure

```
oh-my-agent-env/
├── setup.sh                              # Entry: globals, .env source, dispatcher, small cmd_*
├── lib/                                  # setup.sh helpers (sourced after globals)
│   ├── common.sh                         #   shared helpers (log, link, MCP verify/cleanup, codex hooks, ...)
│   ├── sync.sh                           #   cmd_sync orchestrator, stable phase order
│   ├── sync/
│   │   ├── core.sh                       #   Claude commands/hooks
│   │   ├── rules.sh                      #   Codex/Gemini dirs + global rules
│   │   ├── skills.sh                     #   registry.yaml skill links + statusline
│   │   ├── external-tools.sh             #   context-mode, Codex CLI, LazyCodex, fork install
│   │   ├── plugins-mcp.sh                #   Claude plugins + Claude MCP registration
│   │   └── frameworks.sh                 #   Codex/Antigravity MCPs, Serena, GSD/RTK/Graphify/CRG/codegraph
│   ├── doctor.sh                         #   cmd_doctor loader
│   └── doctor/
│       ├── local-prereqs.sh              #   npm prefix, state dirs, CLI tools, symlinks
│       ├── claude.sh                     #   Claude plugins + Claude MCP surfaces
│       ├── codex-integrity.sh            #   codex-gemini-mcp fork and codex CLI integrity
│       ├── lazycodex.sh                  #   LazyCodex / omo@sisyphuslabs plugin check
│       ├── agent-mcp.sh                  #   Codex/Antigravity MCP and context-mode checks
│       ├── frameworks.sh                 #   managed skills, GSD, RTK, Graphify, CRG
│       └── main.sh                       #   cmd_doctor orchestration
├── ui/statusline/
│   └── my-statusline.mjs                 # Custom statusline (omc-free; reuses cc-alchemy-statusline)
├── runtimes/
│   ├── claude/commands/                  # Claude Code slash commands
│   │   ├── analyze-paper.md
│   │   └── debate-loop.md
│   ├── claude/hooks/                     # Rules-enforcement hooks (see below)
│   │   ├── manifest.json                 #   SSOT: which hooks install AND register
│   │   └── *.js                          #   one file per enforced rule
│   ├── claude/rules-core.md              # Compressed rules injected every turn
│   ├── codex/
│   │   ├── instructions.md               # Codex global rules
│   │   └── tools.md                      # Codex tool guidance
│   └── antigravity/
│       ├── tools.md                      # Antigravity (agy) tool guidance
│       └── skills/
├── rules/                                # SRP-split global rule modules (Layer A)
├── skills/                               # Shared oh-my-agent-env skills (codebase-scan, triangle-review, ...)
├── scripts/                              # Helper shell scripts
│   ├── check.sh                          #   verification gate (lint + tests); CI runs this
│   ├── journal.sh                        #   Obsidian work-journal entries
│   ├── oma-lab                           #   experiment tools entry point (→ ~/.local/bin)
│   ├── lab/                              #   ledger, capsule, board, fail + shared lib
│   └── ...                               #   apply-project-template, snapshot, ...
└── tests/
    ├── smoke-refactor.sh                 # Source graph, isolated HOME, hook contract, journal
    └── fixtures/layer-a-sections.txt  # checked-in Layer A baseline for step [11]
```

`setup.sh` is intentionally kept as the stable user-facing entrypoint. The
`sync` and `doctor` loaders preserve command names while domain files make
runtime parity easier to review: setup mutating domains and diagnostic domains
are now visible in the file tree instead of being hidden in monolithic scripts.

## Rules Enforcement

`rules/*.md` is prose the CLI reads; it is not enforced. The enforced layer is
`runtimes/claude/rules-core.md` — a compressed rule list injected on every turn
— plus one hook per rule that can actually block a tool call.

`runtimes/claude/hooks/manifest.json` is the single source of truth: it decides
both which hook files get symlinked into `~/.claude/hooks/` and which entries get
reconciled into `~/.claude/settings.json`. Adding a hook means adding one entry
there. Anything absent from the manifest is neither installed nor registered.

The two lists used to be maintained separately, and they drifted: three hooks
shipped as files that nothing ever called, on every machine whose `settings.json`
had not been hand-edited. `tests/smoke-refactor.sh` step [7] now fails if a
shipped hook is missing from the manifest, and `setup.sh doctor` reports any hook
that is registered but dead.

Registration is a reconcile, not an append. Entries pointing at a script this
repo ships are rebuilt from the manifest, so a renamed or retired hook converges
instead of lingering; everything else in `settings.json` — `rtk`, `gsd-*`,
`context-mode-cache-heal.mjs`, anything you added — is never inspected or moved.

## Verification

```bash
scripts/check.sh              # lint + tests — run before committing
scripts/check.sh --lint-only  # bash -n, node --check, JSON parse, shellcheck
scripts/check.sh --no-lint    # smoke suite + hook fixtures
```

CI (`.github/workflows/test.yml`) runs the same entry point, with lint and tests
as separate jobs so one lint failure cannot hide every test result. `shellcheck`
is required in CI and skipped with a notice locally.

The smoke suite sandboxes `HOME`, `XDG_*`, `TMPDIR` and git config into one temp
root, so running it never touches your real `~/.claude` or vault.

## Where a Rule Should Live

Rules sit in one of three places, and they are not interchangeable: resident
(`~/.claude/CLAUDE.md`, assembled from `rules/*.md` + `tools.md`), per-turn
(`rules-core.md`, injected by a `UserPromptSubmit` hook), or on-demand (a skill,
loaded only if something calls `Skill`).

```bash
scripts/measure-uptake.sh     # reads ~/.claude/projects, prints aggregates only
```

The obvious way to shrink the resident file is to push rules into skills. Across
179 tool-using transcripts, `Skill` was called 14 times in 9 sessions (5%). Of
those, 12 were slash commands the user typed; 2 were model-initiated. The ToDo
tools, which have a Stop hook behind them, appear in 13%.

Two autonomous loads in 179 sessions is not a channel a rule can depend on, so
that restructuring is not on the table until the number changes. The measurement
does not control for relevance — a session where no skill applied looks the same
as one where a relevant skill was ignored — so it bounds the upside rather than
proving the mechanism.

`tests/smoke-refactor.sh` step [11] guards the related trap: `rules/*.md` feeds
Claude, Codex *and* Antigravity, so a module moved into a Claude-only skill
silently drops the rule for the other two.

## Experiment Tools (`oma-lab`)

Run inside a research repo, not here. `setup.sh sync` links `oma-lab` into
`~/.local/bin`; all state goes to `<repo>/.oma-lab/`, excluded from git through
`.git/info/exclude` so your tracked `.gitignore` stays clean.

```bash
oma-lab run --metrics 'rmse=0.42' --tag baseline -- python train.py --seed 1
oma-lab top --metric rmse --min        # best known baseline, as a lookup
oma-lab board claim --id lr-sweep-01 --hypothesis "3e-4 beats 1e-3"
oma-lab capsule save --config config.yaml --output ckpt-best.pt
oma-lab capsule whence ckpt-best.pt    # which run produced this checkpoint?
oma-lab fail check --cmd "python train.py"
```

| Tool | What it prevents |
|---|---|
| `run` / `top` | Re-deriving a baseline from memory, and losing what was tried |
| `board` | Two sessions starting the same experiment |
| `capsule` | A checkpoint nobody can trace back to code |
| `fail` | Re-running a command that already failed unchanged |

Three things actually block rather than advise:

- `run` executes the research repo's own `scripts/check.sh` first, and a failing
  gate aborts before the command starts. Skipping it needs `--no-gate --reason`,
  and the reason is recorded. That gate is what stops hours of GPU time going
  into code that was already broken. It must never call `oma-lab` back.
- `board claim` refuses an id that is already active. A stale *claim* can be
  taken over after `OMA_BOARD_CLAIM_TTL` (default 1 day); a *running* one never
  can, because a training job outliving its session is normal and stealing its
  id would put two jobs on the same checkpoints.
- `fail check` exits 3 when the same command already failed and the tree has not
  changed since. After edits it only warns — the edits may be the fix.

`rules/70-analysis.md` has always required measuring before claiming. These are
the first mechanisms behind that rule; before them the harness had the norms and
no enforcement.

## Work Journal

```bash
scripts/journal.sh add "what happened" --outcome done --evidence "scripts/check.sh"
scripts/journal.sh path          # today's file
```

Writes to `$OMA_VAULT/Planner/Agent-Journal/YYYY-MM-DD.md` (`OMA_VAULT` defaults
to `~/PROject/vault`) — a dedicated file, never the Templater-owned daily note.
The entry links to `[[YYYY-MM-DD]]` so it surfaces in that day's backlinks
without writing into it. Journalling is fail-open: it warns and exits 0 rather
than blocking whatever called it.

## Prerequisites

- Node.js >= 20
- git, npm
- Claude Code CLI
- (Optional) Antigravity (agy): see https://antigravity.google.com — gemini-cli successor
- (Optional) Codex CLI: `npm install -g @openai/codex`

## LazyCodex for Codex

`setup.sh sync` installs LazyCodex on each machine through its upstream npx
installer:

```bash
npx --yes lazycodex-ai@latest install --no-tui
```

LazyCodex registers in Codex as `omo@sisyphuslabs`, so the expected verification
surface is:

```bash
codex plugin list | grep 'omo@sisyphuslabs'
~/.local/bin/omo --version
```

After the first sync on a new machine, restart Codex App/CLI and approve the
`omo@sisyphuslabs` hooks when Codex asks.

## Project Graphify Setup

`setup.sh sync` installs the global Graphify CLI and links the managed skill into Claude Code and Codex-compatible `~/.agents/skills`.

For each project, run:

```bash
bash setup.sh init-project /path/to/project
```

This appends the Graphify guidance section to `AGENTS.md` and `CLAUDE.md`, installs `.codex/hooks.json` and `.claude/settings.json` hooks, and creates `.graphifyignore` defaults.

## oma (oh-my-agent) Setup

Install/refresh the per-project multi-agent harness:

```bash
bash setup.sh oma /path/to/project   # default: current dir; idempotent
```

This runs `bunx oh-my-agent@latest install`, then:

- **`.agents/oma-config.yaml` is a managed file** — `setup.sh oma` overwrites it from `templates/oma/oma-config.yaml` on every run. This is the single source of truth (cross-machine reproducibility, no drift). **To change config, edit `templates/oma/oma-config.yaml`** (tracked) and re-run — do not hand-edit the generated copy, it is overwritten.
- **statusline** — oma points the project statusLine at its own `hud.ts`. `setup.sh oma` re-pins our unified statusline in `.claude/settings.local.json` (gitignored, outranks project `settings.json`), so it wins and survives every oma re-link. Always install oma via `setup.sh oma` (not `bunx` directly) to keep this pin.

oma's generated tree (`.agents/`, vendor `.claude/*`, `.mcp.json`) is gitignored; only `templates/oma/oma-config.yaml` is tracked.

## Related Repos

- [codex-gemini-mcp (fork)](https://github.com/Byun-jinyoung/codex-gemini-mcp) — `codex-mcp` + `antigravity-mcp` with session resume + multi-turn
- [oh-my-agent](https://github.com/first-fluke/oh-my-agent) — per-project multi-agent harness (installed via `setup.sh oma <path>`)
