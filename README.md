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
| **codex-gemini-mcp** (fork) | MCP server with session resume + gemini `-y` flag |
| **my-statusline.mjs** | Custom HUD: model, branch, 5h/7d usage bars, context, agents, todos |
| **gemini-swarm** | Gemini CLI extension for multi-agent parallel execution |
| **gemini-swarm.md** | Claude Code skill for invoking gemini-swarm |
| **GEMINI.md** | Global reliability rules for Gemini CLI |
| **instructions.md** | Global reliability rules for Codex CLI |
| **OMC patches** | Model-first display order in OMC HUD |

## Directory Structure

```
cc-bootstrap/
├── setup.sh                              # One-command installer
├── hud/
│   └── my-statusline.mjs                 # Custom statusline (OMC HUD wrapper)
├── claude/commands/
│   └── gemini-swarm.md                   # Gemini swarm skill
├── codex/
│   └── instructions.md                   # Codex global rules
├── gemini/
│   └── GEMINI.md                         # Gemini global rules
└── patches/
    └── omc-render-model-first.sh         # OMC HUD model-first patch
```

## Prerequisites

- Node.js >= 20
- git, npm
- Claude Code CLI
- (Optional) Gemini CLI: `npm install -g @google/gemini-cli`
- (Optional) Codex CLI: `npm install -g @openai/codex`

## After OMC Updates

Re-apply patches:

```bash
cd cc-bootstrap
bash patches/omc-render-model-first.sh
```

## Related Repos

- [codex-gemini-mcp (fork)](https://github.com/Byun-jinyoung/codex-gemini-mcp) — session resume + gemini -y
- [gemini-swarm](https://github.com/tmdgusya/gemini-swarm) — multi-agent orchestration
- [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) — workflow orchestration plugin
