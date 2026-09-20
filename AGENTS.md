## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- For cross-module "how does X relate to Y" questions, prefer `graphify query "<question>"`, `graphify path "<A>" "<B>"`, or `graphify explain "<concept>"` over grep — these traverse the graph's EXTRACTED + INFERRED edges instead of scanning files
- After modifying code files in this session, run `graphify update .` to keep the graph current (AST-only, no API cost)

## graft

Prefer graft over raw grep/rg/full-file read for code exploration — ~1/10 the tokens, and it refreshes the structural graph (~3ms, $0, no key) before every query so answers reflect uncommitted edits.

- `graft ask "<task>"` — ranked nodes with file:line and source inlined; usually the whole answer, no follow-up read.
- `graft grep "<regex>"` — exhaustive search grouped by enclosing symbol (use instead of rg for code).
- `graft skeleton <file>` — every signature, no bodies: the API surface for ~1/10 the tokens.
- `graft callers <symbol>` — references; `-d N` walks the transitive blast radius, `--direction out` lists callees.
- `graft map` — token-budgeted repo orientation for an unfamiliar tree.
- The graph lives in graft/ (git-ignored, regenerable); `graft build` rebuilds it. `graft build --deep` adds LLM summaries (needs a provider key).
- Uptake is wired globally through graft hooks (Claude `~/.claude/settings.json`, Codex `~/.codex/hooks.json`, GJC graft-nudge); there is no graft MCP — use the `graft` CLI above.
