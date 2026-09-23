---
name: herdr-council
description: >
  Coordinate persistent Herdr sessions so multiple coding agents independently
  investigate, design, or review the same problem, discuss their conclusions
  directly, and reconcile them before implementation. Use when the user names
  herdr-council, asks multiple Claude Code/Codex/GJC/OMO sessions to discuss or
  cross-check work through Herdr, or accepts a proposal to use this workflow for
  reasoning-heavy work. Do not create sessions merely because parallelism could
  help; propose the council and wait unless the user explicitly requested it.
---

# Herdr Council

Use Herdr as a persistent workspace for independent reasoning, direct agent-to-agent discussion, reconciliation, and then ownership-based implementation. The orchestration session owns the workflow and the final user report.

This skill complements the machine-generated `herdr` skill. Follow that skill and the installed `herdr` binary for current CLI syntax, lifecycle semantics, targeting, and safety. Do not copy or guess Herdr commands here.

## Non-negotiable model

- During investigation, design, and review, every council participant reasons independently about the same whole problem. Do not partition reasoning into role-specific lenses.
- Independent duplicate analysis is intentional cross-validation, not waste.
- After independent answers are fixed, participants use Herdr to question and challenge one another directly.
- Reconcile claims by evidence, never by vote or model count.
- Only implementation is divided by role, file, module, or interface ownership.
- Keep existing sessions open. Keep sessions created by this workflow open too. Close a session only when the user explicitly requests it.

## Invocation policy

Run the council when:

- the user explicitly names `herdr-council`;
- the user asks for multiple agents or runtimes to discuss, cross-check, or reconcile work through Herdr; or
- the user accepts an orchestration-session proposal to use the council.

For a reasoning-heavy task, the orchestration session may propose this workflow. A proposal is not authorization to create or prompt sessions. Wait for acceptance unless the user already explicitly requested Herdr council work.

## Workflow isolation

- Do not invoke or depend on another workflow skill unless the user explicitly requests that workflow.
- Reuse relevant reasoning principles inside `herdr-council` instead of chaining to the original workflow.
- Do not treat a useful pattern from another skill as authorization to execute that skill.
- Apply this isolation rule to the orchestration session and every council participant.
- Include the workflow boundary in the shared context pack sent to every participant.
- Council participants must not invoke additional workflow skills or delegate to agents outside the user-approved roster.
- Return any proposed workflow or roster expansion to the orchestration session.

If the user explicitly requests `herdr-council` together with another workflow, follow an explicit execution order and handoff. Ask before controlling sessions when the order or handoff is material and unclear.

## Language policy

- All inter-session communication is English to reduce token usage. This covers context packs, prompts, independent conclusions, direct questions and rebuttals, reconciliation messages, and implementation handoffs.
- Council participants communicate only with the orchestration session or their explicitly approved peers, and do so in English.
- Only the orchestration session communicates directly with the user. Those user-facing messages and the final report to the user must be in Korean.
- Include this language boundary in the shared context pack sent to every participant.

## Preflight before controlling sessions

A short read-only investigation may establish repository and environment facts. Stop at the first point that needs user interpretation. Before creating or prompting council sessions, report:

```text
Interpreted Intent
Known
Unknown
Needs Verification
Excluded
Proposed Council
Proposed Process
```

Rules:

- Separate observed facts from assumptions.
- If an unknown can materially change the result, ask the user and stop before session control.
- If the user says the interpreted intent is wrong, stop immediately and re-establish intent.
- If the user explicitly requested the council and objective, scope, constraints, and roster are already clear, report the preflight and continue without another approval round.
- If the orchestration session proposed the council, wait for the user to approve the proposed roster and process.

## Council roster and session reuse

The user chooses the participating runtimes and session count. Accept natural language or a lightweight request such as:

```text
herdr-council
agents: claude,codex,gjc,omo
focus: architecture
rounds: 2
```

This is an input convention, not a strict command grammar.

If the user did not provide a roster, propose one and wait for approval. Do not silently choose a default count.

Before creating anything, inspect sessions in the current Herdr workspace, including other tabs:

- Reuse a user-designated suitable idle session.
- Never interrupt a working or blocked session.
- Reuse another workspace only when the user explicitly designates it.
- When no suitable session exists, create one without stealing focus and preserve the working directory.
- Use configured runtime launchers when a runtime is not a native `herdr agent start` kind.
- Give every participant a stable unique name so peers can address it through Herdr.

Do not close any existing or newly created session after the workflow. The user may continue working in it.

## Phase 0: shared context

The orchestration session prepares one frozen context pack and sends the same pack to every participant:

```text
Objective
Interpreted user intent
Constraints
Known facts
Unknowns
Needs verification
Excluded scope
Relevant files and evidence
Requested deliverable
Council roster
Workflow boundary
Language boundary
```

The workflow boundary must tell every participant to use only the approved `herdr-council` protocol, avoid invoking another workflow skill, avoid creating or delegating to agents outside the approved roster, and return proposed scope expansion to the orchestration session.

The language boundary must tell every participant to use English for all inter-session communication and to address only the orchestration session or approved peers. It must also state that only the orchestration session communicates directly with the user, and that user-facing communication is Korean.

Do not ask each participant to remap the repository or rediscover common facts already present in the pack. They must still evaluate the whole problem independently.

## Phase 1: independent reasoning

For investigation, design, and review, each participant independently addresses the same complete question before seeing peers' conclusions.

Require this result shape:

```text
Claims
Evidence
Risks
Open questions
Proposed decision
Confidence and reasons
```

Important claims need an evidence handle such as a file and line, command output, test result, official source, reproducible observation, or explicit logical premise.

Do not expose another participant's answer until all available independent answers are fixed. This prevents anchoring and fake consensus.

## Phase 2: direct discussion through Herdr

The orchestration session identifies agreements, contradictions, missing evidence, and decision-changing questions. It then assigns bounded peer exchanges.

Participants must use Herdr agent targeting to read or prompt the named peers directly. The orchestration session moderates the graph and topic, but must not replace direct discussion with a private synthesis.

Each peer response covers:

```text
Agreements
Challenges
Missing evidence
Changed conclusions
Remaining disagreements
```

Discussion rules:

- Limit an issue to two direct back-and-forth exchanges by default.
- Do not start unrestricted all-to-all chat.
- Do not repeat a claim without new evidence or a sharper falsifiable argument.
- Do not reopen settled issues unless new evidence invalidates the resolution.
- Participants may not create more agents, delegate implementation, or edit product files during reasoning and reconciliation.

## Phase 3: reconciliation

Track each material issue as one claim, merging confirmations and challenges rather than duplicating findings. Use pane history for simple work. For larger councils or multiple disputes, keep a temporary ledger outside the repository, normally under `/tmp`:

```text
ID | Topic | Claim | Author | Evidence | Challenges | Status | Resolution
```

Allowed status values:

- `AGREED`
- `REVISED`
- `EVIDENCE_NEEDED`
- `DEBATE_PERSISTED`

Judge evidence by directness, reproducibility, relevance, and contract authority. Never resolve by majority vote.

The orchestration session may decide a low-risk dispute when evidence clearly favors one conclusion. Escalate to the user when a dispute affects architecture, API, data, security, irreversible work, user preference, or the final action and remains `DEBATE_PERSISTED`.

## Phase 4: implementation ownership

Start implementation only after the reasoning result is reconciled and the user has authorized implementation when authorization is required.

Implementation is the only phase that partitions roles:

- Divide work by explicit file, module, interface, or verification ownership.
- Freeze shared contracts before parallel edits.
- Assign one owner to each overlapping write surface.
- Do not allow two sessions to edit the same file concurrently.
- Give each implementation session the reconciled decision and only its bounded assignment.
- Have the orchestration session integrate the union of changes and run final cross-cutting verification.

Existing council sessions may be reused for implementation when the user-selected roster and ownership boundaries make that safe. Do not close them afterward.

## Final report

Only the orchestration session reports the integrated result to the user. Participant sessions do not issue competing final reports. Per the language policy, this user-facing report is in Korean even though the reasoning and reconciliation that produced it happened in English.

Use this shape when applicable:

```text
Interpreted Intent
Council Composition
Independent Conclusions
Discussion and Changed Positions
Consensus
Remaining Disagreements
Evidence
Rejected Alternatives
Implementation Ownership
Verification
Recommended Action
```

Summarize the discussion by default. Preserve the Herdr sessions so the user can inspect them, and provide transcript or pane details when requested.

## Stop conditions

Stop and ask or report the blocker when:

- the current agent is not inside Herdr;
- user intent is unclear or corrected;
- the user has not approved a proposed council;
- the requested roster is unavailable and substitution changes intent;
- every candidate session is busy or blocked;
- discussion cycles without new evidence;
- implementation ownership overlaps cannot be made safe; or
- a decision-changing dispute remains `DEBATE_PERSISTED`.
