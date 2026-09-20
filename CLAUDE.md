## graphify

This repository has a derived code graph at `graphify-out/`.

- Use graph data only when the current user scope permits reading `graphify-out/`.
- For cross-module architecture or impact questions, prefer `graphify query`, `graphify path`, or `graphify explain` over literal text search.
- After repo-owned code changes, refresh with `graphify update .` unless the accepted scope excludes derived artifacts.
- Project-local workflows are not auto-detected. Run a workflow only through an explicit skill or slash invocation.

## graft

Prefer graft over raw `grep`/`rg`/full-file `read` for code exploration — it costs
roughly 1/10 the tokens and refreshes the graph (~3ms, $0, no key) before every
query, so it always reflects the working tree, uncommitted edits included.

- `graft ask "<task>"` — ranked nodes with file:line and source inlined; usually the whole answer, no follow-up read.
- `graft grep "<regex>"` — exhaustive search grouped by enclosing symbol (use instead of `rg` for code).
- `graft skeleton <file>` — every signature in a file, no bodies: the API surface for ~1/10 the tokens.
- `graft callers <symbol>` — who references it; `-d N` walks the transitive blast radius, `--direction out` lists callees.
- `graft map` — token-budgeted repo orientation (clusters, hubs, hotspots) for an unfamiliar tree.
- The graph lives in `graft/` (git-ignored, regenerable). `graft build` rebuilds structurally; `graft build --deep` adds LLM summaries (needs a provider key).
- Uptake is wired globally through graft hooks (Claude `~/.claude/settings.json`, Codex `~/.codex/hooks.json`, GJC graft-nudge); there is no graft MCP — use the `graft` CLI above.
