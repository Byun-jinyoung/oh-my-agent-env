# What was taken from `oh-my-setting`, and what was not

A colleague's harness ([eightmm/oh-my-setting](https://github.com/eightmm/oh-my-setting))
was compared against this one. This records what was adopted, what was refused,
and the evidence for each, so the same components do not get re-litigated from
memory next time.

Not everything fixed in these rounds came from the comparison. The last section
records the ones that did not, so that work landing in the same window does not
get attributed to a source it had nothing to do with.

That harness is built for a shared, multi-user setting. This one is a single
user on Linux, doing molecular ML across three CLI agents. Most of the size
difference between the two is that assumption, not capability.

## How much of it was actually looked at

An earlier version of this page said the harness had been "reviewed component
by component". It had not, and the sentence was doing real damage: it read as a
completed survey, which is the one claim that stops anyone from looking again.

Measured against the clone: `scripts/*.sh` is **78 files, 24,519 lines**. Read
in substance — enough to reach a verdict — were twelve of them:

| | lines | |
|---|---|---|
| `artifact-index.sh` | 912 | refused |
| `data-manifest.sh` | 590 | → `oma-lab data` |
| `run-capsule.sh` | 564 | → `oma-lab capsule` |
| `run-ledger.sh` | 508 | → `oma-lab run` |
| `experiment-board.sh` | 435 | → `oma-lab board` |
| `change-guard.sh` | 355 | held |
| `fail-ledger.sh` | 322 | → `oma-lab fail` |
| `agent-ml-context.sh` | 273 | refused |
| `run-reconcile.sh` | 253 | → `oma-lab reconcile` |
| `provider-contract.sh` | 237 | partly adopted |
| `fail-ledger-hook.sh` | 87 | → `runtimes/claude/hooks/fail-ledger.js` |
| `check-python.sh` | 43 | → `check.sh` `python syntax` |

That is **12 of 78 files (15%)** and **4,579 of 24,519 lines (19%)** read while
porting. The remaining 66 were then triaged in a second pass — six parallel
readers, one batch each, every one asked for a reproducible local gap rather
than a summary. That pass returned **12 CANDIDATEs**, of which **5 reproduced
here** and were fixed; one was **disproved** on reproduction, and six were
recorded as too weak to act on. See "What the triage of the other 66 returned"
below.

So all 78 files have now been looked at, but not to the same depth: 12 were read
line by line while porting, 66 were read once against a fixed adoption bar. A
`REJECT` on this page means "no gap I could reproduce here", not "this file is
without merit."

Note what the shape of that table says: six of the twelve became `oma-lab` and
two more became gates. The reading was not a survey that happened to find
things worth taking — it was driven by the porting, and stopped where the
porting stopped.

## Two waves, not one

The absorption also did not happen in a single pass, and the earlier version of
this page described only the second one.

**May 2026 — `8a319c9`, "absorb oh-my-setting project-template scripts and
skills".** 14 files, 731 insertions, and genuine code derivation: the
project-template scripts, the Slurm skill generator, and two skills were taken
across and had their paths adapted to this layout. All of it is still in the
tree. Measured file-similarity against the originals sits at **0.31–0.66**,
which is what "adopted and adapted" looks like.

**August 2026 — this page's subject.** Concept-only. Every component below was
reimplemented against a locally reproduced failure rather than ported;
similarity against the colleague's files is **0.01–0.05**, i.e. shared
vocabulary and nothing else.

The distinction matters for attribution. The first wave is derived work and the
commit says so. The second is not, and claiming otherwise in either direction
would be wrong.

## The `oma-lab` layer is derived work, not a local invention

Read the verdicts below without this and they look like two small adoptions
made against a large local codebase. The reverse is true, and the page was
understating it in the direction that flatters us.

Everything under `scripts/lab/` exists because of the colleague's harness. The
founding commit `b9a960e` opens by saying so — *"Ports four properties from
eightmm/oh-my-setting's experiment layer, rebuilt for this harness rather than
copied"* — and the correspondence is one to one:

| `oma-lab` verb | ours | lines | theirs | lines |
|---|---|---|---|---|
| `run` / `top` | `lab/ledger.sh` | 249 | `run-ledger.sh` | 508 |
| `fail` | `lab/fail.sh` | 110 | `fail-ledger.sh` | 322 |
| `board` | `lab/board.sh` | 131 | `experiment-board.sh` | 435 |
| `capsule` | `lab/capsule.sh` | 149 | `run-capsule.sh` | 564 |
| `data` | `lab/data.sh` | 292 | `data-manifest.sh` | 590 |
| `reconcile` | `lab/reconcile.sh` | 234 | `run-reconcile.sh` | 253 |
| | | **1,446** | | **2,672** |

The gap it closed was ours. `rules/70-analysis.md` already required measuring
before claiming and checking for leakage, and **nothing enforced any of it** —
the norms were prose and the mechanism did not exist. The colleague's experiment
layer is where the mechanism came from.

All six landed on 2026-08-02, in the sessions that produced this page
(`b9a960e` → `8762b0e` → `cb88d8a` → `a732756`). `oma-lab` is not prior art the
comparison was measured against. It is the comparison's largest output.

What stayed local is the 46% that was left behind and the departures recorded
per component below — each forced by a defect reproduced here, not by taste.

## The bar a component had to clear

Set before looking at any of them, so the answers could not be fitted to what
was already there:

1. **The problem is real here.** Not real in general — real in a single-user
   molecular-ML repo. A hazard that only exists with concurrent writers does
   not count.
2. **Nothing here already covers it.** Overlapping tools are worse than one
   tool, because the second one is the one nobody remembers to run.
3. **There is a delivery path that does not depend on the model choosing to
   use it.** This is the one that eliminated the most. Across 179 tool-using
   sessions, self-directed skill loads were observed **2 times**. Anything
   whose value requires the model to volunteer is, in practice, off.

## Verdicts

| Component | Verdict | Deciding evidence |
|---|---|---|
| `run-ledger.sh` | **Adopted, rewritten** | `rules/70-analysis.md` demanded measurement and nothing recorded any. Shipped as `oma-lab run` / `top`. |
| `fail-ledger.sh` | **Adopted, rewritten** | A command known to be broken was rediscovered every session. Shipped as `oma-lab fail`. |
| `fail-ledger-hook.sh` | **Adopted, reimplemented** | Ours shipped failing criterion 3: the only automatic caller was `ledger.sh:215`, so anything not run under `oma-lab run --` was remembered only if the model volunteered. Shipped as `runtimes/claude/hooks/fail-ledger.js`. |
| `check-python.sh` | **Concept adopted, no code** | Theirs checks standalone `.py` files; we have none. The gap here was the 39 Python programs embedded in shell, none of them compiled. Shipped as `check.sh`'s `python syntax` stage. |
| `experiment-board.sh` | **Adopted, rewritten** | Two sessions could start the same experiment and neither would find out. Shipped as `oma-lab board`. |
| `run-capsule.sh` | **Adopted, rewritten** | "Which run produced this checkpoint" had no answer. Shipped as `oma-lab capsule`. |
| `data-manifest.sh` | **Adopted, rewritten** | Scaffold-level leakage is real in a one-person repo, and the ledger had no dataset field at all (`scripts/lab/ledger.sh`). Shipped as `oma-lab data`. |
| `change-guard.sh` | **Held** | Half of it is sound; the value depends on a rate that could not be measured. See below. |
| `artifact-index.sh` | **Refused** | It indexes artifacts that nothing here produces. |
| `agent-ml-context.sh` | **Refused** | Its one high-value section breaks on our record format, and we do not own the channel it writes to. |
| `roles/*.md` | **Text only** | The mechanism is already covered; three or four sentences of the content were not. |
| `run-reconcile.sh` | **Adopted, rewritten** | No counterpart here, and the ledger recorded `sbatch`'s exit as the run's. Shipped as `oma-lab reconcile`. |
| `provider-contract.sh` | **Partly adopted, partly unassessed** | The gap it names is real but is not the gap it checks for. Two of its three halves were never evaluated. |

## Adopted: `data-manifest.sh` → `oma-lab data`

The ledger records commit, dirty tree and metrics. Datasets are large and
gitignored, so a commit hash is blind to them **by construction** — the tree
reads clean whatever the CSVs say. "Which dataset version produced this
checkpoint" therefore had no answer, and no other tool here was going to give
it one.

What made it worth porting rather than reimplementing from scratch is one
idea: hashing the sorted `id → value` pairs, not just the columns. Permute
which scaffold each molecule is assigned to and the id set, the value set and
the row count are all unchanged, while the experiment is now measuring
something else. Confirmed by running it: permutation is caught, and row
reordering is correctly *not* flagged.

Roughly 70% of the original was left behind — schema migration, per-manifest
files, sensitive-content scanning, name validation, a bash-3.2 macOS path.
All of it exists to survive many users and many machines.

Two deliberate departures:

- **`leakage` exits 2 when it cannot look.** The original reported clean on a
  missing column. A gate that passes by skipping reads as "no leakage" to
  whatever called it.
- **Split paths resolve against the repo root**, so `--repo` from a Slurm
  submit directory works. This surfaced a wider bug — see below.

Known limit: the id and key columns are held in memory to sort them. Fine for
a wide feature table, wrong for a split large enough to need an external sort.
The real split sizes here have not been measured.

## Held: `change-guard.sh`

Two halves, judged separately.

The **dirty-clobber** half is sound and would work here, because the Stop hook
fires without the model choosing anything. The **scope** half cannot be built:
it checks edits against an `allowed_paths` field our task records do not have.

It is held rather than adopted because its value scales with how often a
session *starts* on a dirty tree, and that number is unknown. 6,863 session
transcripts were scanned; transcripts do not record git state at session start,
so what came back was "a dirty-looking output appeared somewhere in the
session" — 10 of 184. That is a proxy for the wrong thing, and the honest
answer is that the rate was not measured. Adopting on a proxy would mean
carrying a hook whose benefit nobody can state.

## Refused: `artifact-index.sh`

The index has no producer here. Its only writer in the source harness was a
1,639-line delegation library that was already removed from this one
(`peer-common.sh`). A search of this tree finds zero writers.

The failure mode of adopting it anyway is the bad one: it returns an empty
result set for an index nobody populates, which reads exactly like "there are
no artifacts" rather than "this tool is not connected to anything".

## Refused: `agent-ml-context.sh`

Its one genuinely useful section is a ledger tail, and that section breaks on
our records:

- there, a run's `cmd` is a **list**; here it is a **string**. Rendering ours
  through their formatter joins it character by character.
- our `repo` field is an absolute path, so it matches their `/home/`
  sensitive-path filter and the whole section is stripped.

Both are fixable. The reason not to fix them is the third criterion: this
composes an outbound prompt, and the prompt-assembly channel belongs to the
CLI runtimes, not to us. We would be maintaining a renderer whose output
nothing is obliged to read.

## Text only: `roles/*.md`

The mechanism — persona files a model is asked to load — is already covered by
the Agent tool and `oma agent:spawn`. And it is the mechanism the 2-in-179
measurement condemns.

The prose held three checks worth keeping, now in `rules/40-verification.md`:
name the false-green paths before claiming a pass; make a bugfix test fail on
the reproduced bug first; assert observable interfaces rather than internal
state. A fourth went into `rules/20-workflow.md`: look for the smallest check
that could overturn a decision.

**They went to `rules/`, not to `.claude/agents/`.** `.claude/agents/` is
gitignored and regenerated by `oma link`, so anything written there is lost on
the next sync. `rules/*.md` is assembled into all three CLI targets, which is
also the only placement that reaches Codex and Antigravity.

## Adopted: `run-reconcile.sh` → `oma-lab reconcile`

A Slurm job outlives the session that submitted it. `oma-lab run -- sbatch
train.sh` recorded `exit=0`, which is sbatch's exit and means only that the
submission was accepted. If the training OOM'd an hour later, nothing ever went
back to say so, and the row kept claiming success. Reproduced before writing
anything: the ledger had a `slurm_job` field that was write-only and empty on
every submit-from-login-node run, because `SLURM_JOB_ID` is set inside a job and
never in the shell that submits one.

Two pieces, both rewritten rather than ported:

- **`ledger.sh` captures the id.** Only for submitters — putting an arbitrary
  training command's stdout through a file breaks progress bars and tty checks,
  and there is no id in that output anyway. If the capture file cannot be
  created, the submission is **refused**: degrading to "run it uncaptured" puts
  a job in the queue that nothing can ever look up, which is the exact state
  this tool exists to prevent, created silently.
- **`reconcile` asks Slurm how it ended** and appends the outcome beside the
  launch row. It never edits the row — the launch record is what it is.

Departures from the original, each forced by a defect found here:

- **It refuses when it cannot query Slurm** (exit 2). `command -v` answers "is
  the binary on PATH", which is the wrong question: with slurmdbd down, sacct is
  installed and fails every query, so every job came back UNKNOWN and the tool
  printed "0 newly finished, N still open" — word for word what it prints when
  the jobs really are running. So it probes with a question whose answer does
  not depend on any job.
- **Step rows are excluded, element rows are not.** sacct returns one row per
  step (`12345.batch`), and taking the first filed a step's outcome as the job's.
  Fixing that by matching JobID exactly then broke `sbatch --array`, whose rows
  are all named `12345_0`, `12345_1` — no row is ever named the parent id the
  ledger holds, so every sweep read UNKNOWN forever. The rule now names the rows
  that are *not* answers: a step is the row with a dot in it.
- **A sweep's many endings collapse to one, worst-first.** Still-running wins,
  then a non-COMPLETED ending, so an array with a dead element cannot report
  itself COMPLETED and a half-finished one is not filed as over.
- **`run list` reads it.** A file nothing displays answers a question nobody
  gets to ask — the reason `artifact-index.sh` was refused rather than ported.

Known limit: `sacct -n -X -j 0` is the health probe, and whether every Slurm
version answers job 0 without erroring **has not been verified against a real
cluster** — there is none on this machine. If some version errors on it, a
healthy cluster would be refused. Worth one command to check.

## Adopted, reimplemented: the two hook-shaped gaps

Triaging all 78 of the colleague's `scripts/*.sh` left seven candidates, and
five of them were hooks. That is the finding, not the count: what this harness
was missing was rarely a capability and usually a *delivery path* — criterion 3
above, failed by our own tools.

**`fail-ledger-hook.sh` → `runtimes/claude/hooks/fail-ledger.js`.** Same idea,
different facts. The payload shape was read out of the shipped CLI (2.1.220)
instead of assumed, and two of the original's decisions do not survive contact
with it:

- It reads `tool_response.exit_code`. `PostToolUseFailure` sends
  `{tool_name, tool_input, tool_use_id, error: string, is_interrupt?,
  duration_ms?}` — no exit code at all; `tool_response` belongs to
  `PostToolUse`, which the binary's own docs define as the **success** event.
  So its exit code is always the `1` fallback and its 130/141/143 interrupt
  filter is unreachable. Ours drops interrupts by the `is_interrupt` flag and
  does not claim to know an exit code it was not given.
- It prints to stdout, on the stated assumption that "hook stdout becomes agent
  context". For this event stdout is transcript-only; the model never sees it.
  Ours returns `hookSpecificOutput.additionalContext`, which the settings
  schema accepts for `PostToolUseFailure`.

It is silent the first time a command fails and speaks only on a repeat with an
unchanged tree, it never records its own refusals — `fail check` exits 3 by
design, which is itself a failed Bash command — and it will not create
`.oma-lab/` in a repo that never opted in.

**`check-python.sh` → `check.sh`'s `python syntax` stage.** No code crossed:
theirs compiles standalone `.py` files and this repo has none. The reproduced
defect was ours and worse than a crash — a syntax error injected into
`hook_manifest_scripts` left `check.sh` printing PASS, because `2>/dev/null &&
return 0` swallows the `SyntaxError` and falls through to a glob, so
`manifest.json` quietly stops being the SSOT for which hooks get installed
while the output still looks like a list of hooks. What was taken is the one
idea their script has that a naive version lacks: *if nothing was checked, that
is a failure too.* Ours extends it — an unreachable site fails unless it is
named in a checked-in list, and a stale name in that list fails as well.

## Partly adopted, partly unassessed: `provider-contract.sh`

The premise is right and matters more here than there: this harness assembles
one rule set into three targets (`rules/*.md` + `runtimes/<cli>/tools.md` →
CLAUDE.md, AGENTS.md, GEMINI.md), so if they silently diverge, every other
guarantee is downstream of a false one.

But the contract it checks was already half-covered. `tests/smoke-refactor.sh`
step [11] asserts every Layer A heading reaches all three targets. What it
cannot see is the production failure, because it assembles into an empty sandbox
every time: a target that already exists, is skipped this run, and keeps serving
the previous rules. Reproduced — `write_managed_block` had two refusal paths
that returned success, `assemble_global_rules` printed `[OK]` over them, and
sync's closing line said "complete".

So what was adopted is the *idea*, applied to the mechanism we actually have:
the refusal paths now return 3, a partial assembly returns nonzero and names
which runtime stayed behind, and sync counts it as an error instead of
reporting success.

**Two of the original's three halves were not evaluated at all**: MCP
registration parity across providers, and detecting hooks that fail open into
no-ops. Neither has been shown to be a gap here, and neither has been shown not
to be. They are open, not closed.

## What the review process itself turned up

Adversarial cross-review found a class of bug that neither the unit checks nor
the first end-to-end pass caught: `--repo` redirected **where state was
written** while every git read still ran against the caller's cwd. A job
launched from a submit directory wrote its ledger into the target repo and
stamped each row with the *launcher's* commit — a record that looks
authoritative and answers the one question it exists for with the wrong answer.

Three separate symptoms, one cause, all reproduced before fixing and
re-reproduced after. The e2e assertions that let it through asserted that
files landed in the right repo, never that they *described* the right repo.

The general lesson is already in `rules/40-verification.md`: static checks,
end-to-end runs, and adversarial review each catch a different failure mode,
and a green result from one says nothing about the other two.

The Slurm round added a fourth, and it is the uncomfortable one: **a fix is a
change, and a change can be the next defect.** Excluding step rows by matching
JobID exactly was correct about the bug it targeted and broke every array job in
the process — a silent regression, shipped inside a commit whose message was
about preventing silent regressions, and it survived a full green e2e run
because no test had ever submitted a sweep.

What caught it was neither the test suite nor re-reading the diff. It was
mutation testing plus a second adversarial pass, which agreed on it
independently. Two of the assertions written in the same session turned out to
be vacuous under mutation — one used a fixture whose stub ignored the very flag
the assertion was about, the other picked a scenario a downstream check already
handled, so removing the mechanism under test changed nothing. Both passed.
Both proved nothing.

So the rule that came out of it: **a new assertion is not finished when it
passes. It is finished when breaking the mechanism it names makes it fail.**

## What the triage of the other 66 returned

Six readers, one batch each, all read-only. Each was given the same bar as the
first wave — a gap that is real *here*, not already covered, and delivered
through a path the model does not have to choose — and asked for a command I
could run in this tree rather than a description. Twelve came back as
CANDIDATE. I re-ran every one before writing any code.

Five reproduced and were fixed:

| Gap | Reproduced by | Fix |
|---|---|---|
| 12 tracked `.py` files were parsed by no stage | `git ls-files '*.py' \| wc -l` = 12; no stage reads them | `check.sh` python stage extended to files (`082fee7`) |
| this shell harness classified as an ML project | `bash scripts/detect-project-style.sh .` → `ml` | anchored imports / manifests (`6b007f8`) |
| switching base style stacked two rule sets | general then ml → 151-line CLAUDE.md, both blocks | stale base-style removal (`c512100`) |
| `.oma-lab/CURRENT` could name a run the ledger did not have | bogus id → `capsule save` succeeded and made `runs/<bogus>/` | ledger-checked fallback (`695684e`) |
| `local/machine.md` cited by 4 surfaces, generated by none | file absent; `grep -rn write-machine-snapshot setup.sh lib/` → nothing | sync writes it, doctor verifies (`4cfe397`) |

One was **disproved on reproduction**: a validator for `skills/registry.yaml`,
reported as needed because `skills/paper-analyzer/` has no top-level `SKILL.md`.
It does not need one — `lib/sync/skills.sh:41-42` resolves `path/<runtime>`
first, and that skill ships `codex/` and `gemini/` subdirectories. There are no
dangling skill symlinks on this machine. The finding was an assumption about
layout, and it is the reason every CANDIDATE gets re-run rather than trusted.

Six were left alone, with the reason recorded so the decision can be revisited:

- **`provider-permissions.sh`** — real on paper, but our only `agy` caller is
  `antigravity-mcp`, which hardcodes `--dangerously-skip-permissions`, and
  nothing else in `scripts/` or `runtimes/` shells out to `agy`. Nothing to
  defend today.
- **`skill-router.sh`** — guarantees a hint is *delivered*, not acted on, and
  would inject against 91 installed skills on every prompt. The cost is certain
  and the benefit is not measured.
- **`precompact-handoff.sh`** — writes a lossless goal/file digest at
  compaction, which we do not do. Nothing reads it back, in either harness.
- **`research-runner.sh`** — pre-registering hypothesis and success criteria
  before a run is the right idea, but `rules/70-analysis.md` already says it;
  what is missing is enforcement, not the requirement. Worth doing as a small
  change to `oma-lab run`, not as a 216-line port.
- **`job-digest.sh`** — extracting the real traceback from a large Slurm log is
  a genuine gap, but as shipped it is a CLI the model must volunteer, and the
  measured rate for that is ~2 self-directed loads in 179 sessions.
- **`install-hooks.sh`** — a `pre-push` hook running `check.sh`. Verified absent
  (`core.hooksPath` unset, `.git/hooks` is 12 `.sample` files). Writing into
  `.git/hooks` is the user's call, not mine — so this became a command instead
  of a sync step. See below.

## Adopted as a command, not a sync step: the pre-push gate

`scripts/install-hooks.sh` installs a `pre-push` hook that runs `scripts/check.sh`
before anything leaves the machine. `setup.sh sync` does not call it and must not:
sync runs unattended and across machines, and installing something that can block
a push is a decision, not a convergence step.

The cost was measured before deciding what the hook should run: `check.sh` takes
22s across its 8 stages, 11s with `--lint-only`. A push is infrequent enough to
pay 22s for exactly the gate CI runs, so the hook runs the full thing rather than
a cheaper subset that would disagree with CI.

Three properties make it either useless or destructive, so [22] holds all three:
it fails the push when the gate fails; it fails **closed** when `scripts/check.sh`
is missing, because a gate that waves a push through on its own disappearance
reports the same success as a clean run; and it refuses to replace or delete a
`pre-push` hook it did not write (`--force` moves the original aside, never
overwrites a previous backup). A repo with `core.hooksPath` set is refused
outright — writing to `.git/hooks` there installs a hook that never runs.

Escape hatches: `git push --no-verify` once, `OMA_SKIP_PREPUSH=1` always,
`scripts/install-hooks.sh --uninstall` permanently.

## What running it turned up, which the comparison did not

Five commits in this round came from no part of the process above. serena
stopped connecting, and pulling that thread found four more defects of the same
shape underneath. They are recorded here because the structure of this page —
twelve files read, sixty-six triaged, twelve CANDIDATEs — has no slot for a
finding that arrives by *operating* the harness rather than by reading someone
else's. Leaving them out would make the comparison look like the only channel
that produces work. In this round it was not even the one that produced the most.

| Defect | Reproduced by | Fix |
|---|---|---|
| serena provisioned as two different builds sharing one config file | `setup.sh:286` installs the release (`uv tool install serena-agent`, 1.6.1, wants `languages:`); `lib/sync/plugins-mcp.sh:312` registered `uvx --from git+…` (HEAD, writes `language_servers:`). `RENAMED_FIELDS` maps neither spelling to the other, so whichever ran last left a file the other answers with `KeyError` | one build, at every surface (`e2a91cd`) |
| `add_mcp` called a registration correct because the *name* was present | the pre-fix check was `if echo "$mcp_list" \| grep -q "$name"` — the command was never compared, so an entry pointing at the wrong program survived every sync | compare the spec (`e2a91cd`) |
| …and its PATH comparison could never match | it read `claude mcp get`, which answers about the project `.mcp.json` entry and prints no `env` line at all. The comparison therefore always disagreed, and serena was torn down and re-registered on *every* sync — idempotence lost in the direction that looks like activity | read the user scope directly: `mcp_user_field`, `mcp_cmdline_drift` (`e2a91cd`) |
| the same name-only skip in the third surface | pre-fix `lib/sync/frameworks.sh:173` was `if name in mcp_servers and name not in preserved: continue`, and `~/.gemini/config/mcp_config.json` still named `uvx --from git+…`. agy starts that entry in whatever directory antigravity runs from, which is why the breakage read as intermittent | spec comparison, plus reporting the repoint that was already being collected and never printed (`8d69671`) |
| the codex runtime dep check had never once run | `python3 -c 'import tomllib'` → `ModuleNotFoundError` on this machine's 3.10.12. The check printed `[SKIP]` and `__WARN__0` — byte-identical to a clean pass | a minimal TOML parser, `load_min` (`d9e79e6`) |
| doctor said `[MISS] serena` and gave no reason | the reason logic asks whether the *command* resolves, and it did; the fault was in `.serena/project.yml`, which nothing looked at | read the required fields out of the installed build and compare them against the config's top-level keys (`53ee45b`), and pin the existing reason logic to the distinction it exists for (`7f4f270`) |

Three things generalise, and each had already appeared on this page in a weaker
form:

**One tool, one provisioning path.** serena had three that disagreed about which
build to run — `setup.sh`, `lib/sync/plugins-mcp.sh`, and agy's shared
`mcp_config.json`. Two were found and fixed; the third was missed, and a restart
put the breakage straight back. The cost of an extra path is not the duplication,
it is that fixing the visible ones feels like finishing.

**A name is not a spec.** The identical defect — name present, therefore assume
correct — sat in three independent places. Every one of them was replaced with a
comparison against the intended command.

**"Could not check" must not print like "passed."** The codex check is the clean
case: it reported the same zero warnings a clean run reports, for an entire
python version. The same rule now shapes the fixes around it — the pre-push hook
fails closed when its own gate script is missing, the TOML parser warns on a
quoted header it cannot read, and the new schema check warns rather than passing
when it cannot ask the installed build what it requires.

None of this was written before the failure was reproduced locally, and no
assertion was accepted for passing. `[19]`–`[24]` in `tests/smoke-refactor.sh`
extract the logic out of `lib/` with `awk` and run it against fixtures, because
an assertion that restates the logic keeps passing after the original changes.
Each was then checked by breaking the mechanism it names. Two had to be
rewritten: one whose fixture lacked the very field the assertion was about, and
one that died on an extraction guard rather than on the assertion under test —
a kill that proves nothing about the check it was meant to exercise.
