# Attitude-gate hooks (GJC pre_tool_use)

Deterministic enforcement of the user's most-repeated work-attitude rules, so they
do not have to be re-injected as prompt templates (which bloat context and are
ignored anyway). Text raises compliance probability; these hooks **enforce**.

## Files (tracked)

- `runtimes/gjc/hooks/pre/_gate.ts` — single source of truth (all logic).
- `runtimes/gjc/hooks/pre/{write,edit,bash}.ts` — thin per-tool wrappers importing `_gate.ts`.
- `runtimes/gjc/hooks/attitude-gate.example.json` — config template.

Loose-surface loading: a hook file's name must equal the tool it guards
(`write.ts` guards the `write` tool, etc.). `_gate.ts` (underscore) is imported,
not loaded as a hook. Deployed to `~/.gjc/agent/hooks/pre/` by `setup.sh sync`
(`sync_gjc_hooks`).

## Gates

| Gate | Rule | Type | Signal |
|---|---|---|---|
| specExists | 합의된 scope/spec 존재 | HARD | `.gjc/spec.md` exists & non-empty |
| specReferenced | spec 참조 | FORM | a `read` of the spec occurred this session |
| intentReported | 의도 보고 전 mutation 금지 | FORM | an `INTENT:`/`의도:` line in assistant text |
| investigated | 조사 없이 구현 금지 | FORM | ≥ `minInvestigations` read/search/find/grep/list |
| todoActive | 미완 작업 등록 강제 | FORM (opt-in) | a `todo_write` list or `goal(create/resume)` this session |

`todoActive` exists to keep GJC compaction **auto-continue** alive: auto-continue
only resumes a turn while there is unfinished work (an active goal or
pending/in_progress todos). Forcing the model to register a `todo_write` list or
`goal(create/resume)` before it may mutate guarantees that signal exists, so the
session keeps itself going instead of stopping with "no unfinished work detected".
Default **off** (opt-in per machine) so a global install stays a no-op.

Applied to every filesystem mutation: `write`, `edit`, and **mutating `bash`**
(redirection, tee, sed -i, cp, mv, touch, …). Read-only bash passes freely.
Bash coverage is essential — without it the model bypasses write/edit via
`echo > file` (verified).

## Config

Merge order (later wins): built-in defaults ← `~/.gjc/agent/hooks/attitude-gate.json`
(user) ← `<project>/.gjc/attitude-gate.json` (project).

```json
{ "enabled": false, "specPath": ".gjc/spec.md", "minInvestigations": 1,
  "failClosed": false,
  "gates": { "specExists": true, "specReferenced": true, "intentReported": true, "investigated": true, "todoActive": false } }
```

- **Default `enabled: false`** → a global install is a NO-OP until opted in; it
  never bricks a project that has no spec. (verified)
- `failClosed`: on internal hook error, `true` blocks (safe), `false` allows
  (never brick). Default `false`.
- Each gate individually toggleable.

## How enforcement behaves

`{ block: true, reason }` stops the tool call regardless of the model's decision.
The model reads `reason`, adapts (writes/reads the spec, emits INTENT,
investigates), and retries — the gate changes behavior, it is not advisory text.
A thrown handler error also blocks (fail-closed at the runner); the hooks catch
internally and honor `failClosed` instead.

## Verification

- Unit tests: `bun test tests/attitude-gate.test.ts` — 13/13 (pure logic:
  `isMutatingBash`, `scanEntries`, `decide`, `mergeConfig`, `loadConfig`).
- E2E (anthropic/claude-haiku-4-5; codex was rate-limited):
  - no config → write passes (safe default).
  - enabled + no spec → write/mutating-bash blocked.
  - enabled + spec read + INTENT → mutation allowed.
  - bash `echo > file` bypass → blocked when gated.

## Honest limits

- Gates enforce **form**, not depth: an `INTENT:` line and one `read` satisfy the
  form; they do not prove the intent/investigation was substantive. Semantic
  "is this change within the spec" is an LLM judgment, not a pre-tool check.
- **Timing:** `intentReported`/`specReferenced` must appear in a turn *before*
  the mutation tool call. If the model emits intent in the same turn as the
  mutation, the first attempt may block and the model retries. By design.
- Bash mutation detection is a conservative heuristic; exotic write paths (e.g.
  a custom interpreter opening a file) can slip through. Best-effort, not a sandbox.
- The gate blocks the **action**, not a false narrative — a model may still
  *claim* success after a block. Trust the real side-effect, not the model's text.

## Activation (global)

1. `setup.sh sync` (deploys hooks + seeds disabled config).
2. Set `enabled: true` in `~/.gjc/agent/hooks/attitude-gate.json`.
3. Per project, record the agreed scope in `<project>/.gjc/spec.md`.

## Revert / uninstall

`runtimes/gjc/revert.sh` cleanly removes what `setup.sh sync` deployed. Every mutated file
is backed up to `<file>.revert-bak.<timestamp>` first, so revert is reversible.

```bash
runtimes/gjc/revert.sh --dry-run     # show what would change, touch nothing
runtimes/gjc/revert.sh               # remove attitude-gate hooks + seeded config + harness .gjc/config.yml
runtimes/gjc/revert.sh --settings    # ALSO strip compaction/contextPromotion/memory/memories from ~/.gjc/agent/config.yml
runtimes/gjc/revert.sh --yes         # skip the confirmation prompt
```

- Removes only the four installed hook files (`_gate/write/edit/bash.ts`); any
  other hook you placed in `hooks/pre/` is left untouched (verified).
- Default scope keeps your GJC compaction/memory tuning; `--settings` also
  removes those blocks (your `modelRoles`, `task`, `theme`, … are preserved).
- Honors `GJC_CODING_AGENT_DIR`.
