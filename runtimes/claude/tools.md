# Claude Code — tool guidance

Claude Code has hooks. RTK and context-mode are hook-enforced, so most routing
is automatic. The notes below cover what still needs deliberate behavior.

## context-mode

context-mode MCP tools are available and a PreToolUse hook routes token-heavy
commands automatically. Still apply the **Think in Code** principle: to
analyze/count/filter/compare/parse data, write code via
`ctx_execute(language, code)` and print only the answer — do not pull raw data
into context. `ctx_batch_execute(commands, queries)` runs many commands and
searches in one call. `ctx_fetch_and_index(url, source)` for web content.

After `/clear` or `/compact` the knowledge base persists — `ctx purge` to reset.

## RTK - Rust Token Killer

RTK is a token-optimized CLI proxy (60-90% savings). A Claude Code hook
rewrites token-heavy commands transparently (`git status` → `rtk git status`),
so no manual prefixing is needed.

Meta commands, run `rtk` directly:

```bash
rtk gain              # token savings analytics
rtk gain --history    # command usage history with savings
rtk discover          # analyze history for missed opportunities
rtk proxy <cmd>       # raw command, no filtering (debugging)
```

If `rtk gain` fails: possible name collision with reachingforthejack/rtk
(Rust Type Kit) — verify with `which rtk`.

## Skills

Shared skills are synced into `~/.claude/skills/` from oh-my-agent-env by
`setup.sh sync` (registry.yaml-driven). Available:

- `graphify` — any input to knowledge graph. Trigger: `/graphify`.
- `codebase-scan` — orchestrated codebase comprehension for unfamiliar projects.
- `triangle-review` — 3-way parallel code review (Claude + Codex + Gemini).
- `slurm-hpc` — Slurm/HPC workflow helper.
- `spec-interview` — spec-first interview before coding unclear requests.
- `git-cli-workflow` — local git/gh CLI workflow.
- `multi-agent-review` — independent multi-agent review for high-risk changes.

When the user types `/graphify`, invoke the Skill tool with `skill: "graphify"`
before doing anything else.

## graphify project graphs

If a project has `graphify-out/`:
- Read `graphify-out/GRAPH_REPORT.md` for god nodes and community structure
  before answering architecture or codebase questions.
- For cross-module "how does X relate to Y" questions, prefer
  `graphify query`, `graphify path`, `graphify explain` over grep.
- After modifying code files, run `graphify update .` to keep the graph current.
