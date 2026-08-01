# What was taken from `oh-my-setting`, and what was not

A colleague's harness ([eightmm/oh-my-setting](https://github.com/eightmm/oh-my-setting))
was reviewed component by component against this one. This records what was
adopted, what was refused, and the evidence for each, so the same five
components do not get re-litigated from memory next time.

That harness is built for a shared, multi-user setting. This one is a single
user on Linux, doing molecular ML across three CLI agents. Most of the size
difference between the two is that assumption, not capability.

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
| `data-manifest.sh` | **Adopted, rewritten** | Scaffold-level leakage is real in a one-person repo, and the ledger had no dataset field at all (`scripts/lab/ledger.sh`). Shipped as `oma-lab data`. |
| `change-guard.sh` | **Held** | Half of it is sound; the value depends on a rate that could not be measured. See below. |
| `artifact-index.sh` | **Refused** | It indexes artifacts that nothing here produces. |
| `agent-ml-context.sh` | **Refused** | Its one high-value section breaks on our record format, and we do not own the channel it writes to. |
| `roles/*.md` | **Text only** | The mechanism is already covered; three or four sentences of the content were not. |

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
