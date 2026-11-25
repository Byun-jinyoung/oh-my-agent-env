---
name: claude-relay
description: Start, resume, and inspect persistent local Claude Code conversations from Codex using `claude -p` and `--resume`. Use when Codex needs a multi-turn Claude consultation, a parallel second-model opinion, follow-up questions in the same Claude session, or verification of the actual Claude model and effort. Do not use for the interactive Claude TUI or browser Claude.
---

# Claude Relay

Use the bundled CLI to keep one exact Claude Code session across separate subprocess calls. Claude Code restores context from its local transcript; do not simulate continuity by copying only the last answer.

## Command

Set the script path once in the current shell command:

```bash
CLAUDE_RELAY="$HOME/.codex/skills/claude-relay/scripts/claude_relay.py"
```

Run scripts with `uv run "$CLAUDE_RELAY"`. The default configuration explicitly requests `opus`, effort `high`, permission mode `plan`, and no Claude tools.

## Start a session

```bash
uv run "$CLAUDE_RELAY" start \
  --cwd /absolute/project/path \
  --prompt "Your self-contained first question"
```

Capture `session_id` from the JSON result. Also check `ok`, `model_actual`, and `effort_actual`. Treat a missing actual value as unverified, not as proof that the requested value was used.

For a read-only code consultation, add `--tool-profile read-only`. This enables only `Read`, `Grep`, and `Glob`. Keep the default `none` for pure discussion.

## Continue the same session

```bash
uv run "$CLAUDE_RELAY" resume \
  --session-id SESSION_UUID \
  --cwd /absolute/project/path \
  --prompt "Follow-up question referencing earlier turns"
```

Always use the exact returned UUID. Never replace a failed resume with a new session unless the user explicitly accepts losing the prior context. Do not use `--continue`, because another Claude process may have created a newer unrelated session.

## Inspect session evidence

```bash
uv run "$CLAUDE_RELAY" inspect --session-id SESSION_UUID
```

Use inspection when the user asks which model or effort actually served the session. Report the transcript-derived `model_actual`, `effort_actual`, turn counts, and compaction count.

## Parallel consultation

When the user explicitly requests parallel or subagent work:

1. Start the Claude consultation as an independent read-only lane.
2. Run Codex subagents only on non-overlapping work.
3. Continue the Claude session with `resume` when new evidence or a Codex result needs review.
4. Synthesize agreements, disagreements, and unresolved checks in the parent Codex response.

Do not let Claude and Codex edit the same working tree concurrently. Prefer Claude as an advisor. If Claude must edit, use an isolated worktree and obtain any authorization required by the parent task.

## Prompt contract

Give Claude:

- the concrete objective;
- verified files, commands, or results available so far;
- explicit unknowns and excluded scope;
- one bounded question;
- the required response format.

On follow-up turns, state what changed since the previous Claude response. Do not resend the entire conversation; `--resume` restores it.

## Failure handling

- `ok: false`: surface the error and preserve the session ID.
- Exit code `2`: local validation, executable discovery, transcript, or JSON error.
- Exit code `1`: Claude invocation completed unsuccessfully.
- Timeout: do not assume the request failed remotely; inspect the session before retrying.
- Missing transcript: report model and effort as unverified.

Never add `--dangerously-skip-permissions`. The `all` tool profile removes the explicit tool restriction and must be used only when the user authorized Claude to act, not merely advise.
