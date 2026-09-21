# graft/graphify field measurement — when the code graph actually saves tokens

Wiring is done: graft/graphify pre-hooks are deployed and enabled for GJC, and
graphify-freshness hooks are synced for Claude/Codex (see
`lib/sync/agent-clis.sh` `sync_gjc_hooks` / `sync_graphify_hooks`,
`lib/common.sh` `write_graphify_project_config`). The open question was never
"is it wired" — it was "does routing code investigation through graft instead
of grep/read actually pull fewer bytes into the model's context, and when."

This file answers that from measurement on this repo's own files, not intuition
(same reason `scripts/measure-uptake.sh` exists). Byte counts are a proxy for
context tokens (~4 B/token); all numbers below are `wc -c` of the exact output a
path drops into context.

Measured 2026-09-21 on `~/.oh-my-agent-env` @ `master`, graft graph fresh
(`graft/.graph/wiring.json` 12:57), graphify graph stale (`graphify-out/graph.json`
2026-09-09, AST-only).

## Result 1 — `graft skeleton` vs reading the whole file (target: file structure)

| file | full read | skeleton | ratio | verdict |
|---|---|---|---|---|
| `runtimes/gjc/hooks/pre/_gate.ts` (TS) | 8914 B | 1302 B | **6.8x** | real win — full interface+fn signatures with line ranges |
| `runtimes/gjc/hooks/pre/_graft-nudge.ts` (TS) | 10525 B | 1846 B | **5.7x** | real win |
| `lib/sync/agent-clis.sh` (bash) | 22439 B | 80 B | 280x | **artifact** — skeleton is near-empty, does not parse bash |
| `lib/common.sh` (bash) | 50076 B | 71 B | 705x | **artifact** — same under-extraction |

`graft skeleton` is a genuine 5–7x context reduction on **TS/JS** (it emits
signatures + line ranges you can then jump into precisely). On **bash/shell** it
returns almost nothing useful, so the 280–705x figures are under-extraction, not
compression — do not route shell-file orientation through `graft skeleton`.

## Result 2 — `graft callers` vs `grep -rn` (target: enumerate references)

| symbol | grep | graft callers | ratio | verdict |
|---|---|---|---|---|
| `isMutatingBash` (31 grep hits) | 2691 B | 770 B | **3.5x** | win — grep floods, graft ranks |
| `sync_graphify_hooks` | 245 B | 87 B | 2.8x | mild win |
| `graftPointers` (few refs) | 249 B | 548 B | **0.5x** | **loss** — graft's structured output costs more than a tight grep |

The win scales with grep noise. A high-frequency token (`isMutatingBash`, 31
hits across files) makes grep dump 2.7 KB of triage that graft collapses to a
ranked 770 B. A rare symbol already has a tight grep footprint, and graft's
structured framing can cost *more* than grep.

## Result 3 — `graft ask` + read-exact-pointer vs grep + read-window

Locating "where is X defined and what does it do":

| question | grep+read window | graft ask + read exact range | ratio |
|---|---|---|---|
| Q1 `sync_graphify_hooks` (4 hits) | 3085 B | 949 B | 3.25x |
| Q2 `write_graphify_project_config` (2 hits) | 3974 B | 1359 B | 2.92x |
| Q3 `isMutatingBash` (31 hits) | 5574 B | 829 B | 6.72x |

Caveat, stated honestly: `graft ask` returns a *ranked pointer*, and top-1 is
not always the definition (for Q1 top-1 was a call site in `_graphify-nudge.ts`,
not the `agent-clis.sh` definition). Part of the byte savings here is graft
answering a narrower slice than the blind read window — real, but confounded.
The clean, un-confounded wins are Results 1 (TS skeleton) and 2 (high-frequency
callers).

## Result 4 — `graphify query` (stale graph, blocked from refresh)

The graphify graph is `graphify-out/graph.json` @ 2026-09-09 (12428 nodes).
`graphify update .` (AST-only, $0) re-extracted 1069/1069 files but **refused to
overwrite** (new graph 11396 nodes < existing 12428) and demanded `--force`.
`--force` is a prohibited operation here (graft/graphify graph is graft-owned;
no `--force`, no direct `graph.json` edit), so the graph stays stale.

Consequence, measured against the stale graph:

| query | graphify query | grep | note |
|---|---|---|---|
| `isMutatingBash` | 25 B ("No matching nodes") | 374 B | graphify **misses** current symbols on a stale graph |
| `sync_graphify_hooks` | 25 B ("No matching nodes") | 245 B | same miss |
| "attitude gate evaluate" | 6188 B (BFS depth-2, 64 nodes) | 0 B | different modality — concept traversal, not a grep substitute |

graphify `query` is a BFS concept-traversal over the semantic graph, not a
symbol grep. On a **stale** graph it returns nothing for symbols added after the
last extraction, so it cannot be trusted for current-symbol lookup here. A fair
graphify-side token measurement needs a fresh graph, which is blocked on the
`--force` prohibition — recorded as a real limitation, not a graphify win/loss.

## Bottom line — routing rule

- **Route to graft** when: orienting in a **TS/JS** file (`skeleton`), or
  enumerating references to a **frequently-occurring** symbol (`callers`/`ask`).
  These are 3–7x context reductions on this repo.
- **Keep grep/read** when: the target is a **shell/bash** file (graft skeleton
  under-extracts), or a **rare** symbol whose grep footprint is already a few
  lines (graft adds overhead, up to 2x worse).
- graft/graphify is a **targeted** token saver, not a universal one. The nudge
  hooks should push the graph for the first two cases and stay out of the way
  for the last two.

## Not done (user-gated)

- `--deep` (LLM summaries: `graft build --deep`, `graphify update . --deep`) —
  needs API key; not run.
- graphify graph is stale (2026-09-09) and cannot be refreshed without `--force`
  (prohibited). Refreshing it (owner decision) is the prerequisite for any
  trustworthy graphify-side measurement.
- Committing this file and any graft/graphify artifacts is a separate user gate.
