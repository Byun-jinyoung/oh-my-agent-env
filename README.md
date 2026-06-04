# cc-bootstrap

One-command Claude Code environment setup for multiple machines.

## Quick Start

```bash
git clone https://github.com/Byun-jinyoung/cc-bootstrap.git
cd cc-bootstrap
bash setup.sh
```

## What It Installs

| Component | Description |
|---|---|
| **codex-gemini-mcp** (fork) | MCP servers `codex-mcp` + `antigravity-mcp` with multi-turn `session_id` resume (Gemini provider removed 2026-06-18) |
| **my-statusline.mjs** | Custom HUD: model, branch, 5h/7d usage bars, context, agents, todos |
| **GEMINI.md** | Global reliability rules for Antigravity (agy reads `~/.gemini/GEMINI.md` via gemini-cli inheritance) |
| **instructions.md** | Global reliability rules for Codex CLI |
| **OMC patches** | Model-first display order in OMC HUD |
| **Graphify** | Knowledge graph CLI (`graphifyy` package, `graphify` command), Claude/Codex skills, and project hooks |

## Directory Structure

```
cc-bootstrap/
├── setup.sh                              # Entry: globals, .env source, dispatcher, small cmd_*
├── lib/                                  # setup.sh helpers (sourced after globals)
│   ├── common.sh                         #   shared helpers (log, link, MCP verify/cleanup, codex hooks, ...)
│   ├── sync.sh                           #   cmd_sync body (plugins, MCP, frameworks)
│   └── doctor.sh                         #   cmd_doctor body (diagnostics)
├── ui/statusline/
│   └── my-statusline.mjs                 # Custom statusline (OMC HUD wrapper)
├── runtimes/
│   ├── claude/commands/                  # Claude Code slash commands
│   │   ├── analyze-paper.md
│   │   └── debate-loop.md
│   ├── codex/
│   │   ├── instructions.md               # Codex global rules
│   │   └── tools.md                      # Codex tool guidance
│   └── antigravity/
│       ├── tools.md                      # Antigravity (agy) tool guidance
│       └── skills/
├── rules/                                # SRP-split global rule modules (Layer A)
├── skills/                               # Shared cc-bootstrap skills (codebase-scan, triangle-review, ...)
├── scripts/                              # Helper shell scripts (apply-project-template, snapshot, ...)
└── patches/
    └── omc-render-model-first.sh         # OMC HUD model-first patch
```

## Prerequisites

- Node.js >= 20
- git, npm
- Claude Code CLI
- (Optional) Antigravity (agy): see https://antigravity.google.com — gemini-cli successor
- (Optional) Codex CLI: `npm install -g @openai/codex`

## Project Graphify Setup

`setup.sh sync` installs the global Graphify CLI and links the managed skill into Claude Code and Codex-compatible `~/.agents/skills`.

For each project, run:

```bash
bash setup.sh init-project /path/to/project
```

This appends the Graphify guidance section to `AGENTS.md` and `CLAUDE.md`, installs `.codex/hooks.json` and `.claude/settings.json` hooks, and creates `.graphifyignore` defaults.

## After OMC Updates

Re-apply patches:

```bash
cd cc-bootstrap
bash patches/omc-render-model-first.sh
```

## Related Repos

- [codex-gemini-mcp (fork)](https://github.com/Byun-jinyoung/codex-gemini-mcp) — `codex-mcp` + `antigravity-mcp` with session resume + multi-turn
- [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) — workflow orchestration plugin
