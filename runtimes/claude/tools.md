# Claude Code — tool guidance

Claude Code has hooks. RTK and context-mode are hook-enforced, so most routing
is automatic. The notes below cover what still needs deliberate behavior.

## 압축 게이트 — 작업 단위 경계에서 압축

auto-compact이 작업 도중에 터져 맥락이 끊기는 것을 막는다. PreCompact 훅이 마커를 보고 압축을 미룬다.

- 다단계 작업(ToDo 2개 이상)에 착수하면 `~/.claude/hooks/compact-gate busy "<작업명>"`.
- ToDo 하나를 completed로 바꾸는 시점(=작업 단위 경계)에 `~/.claude/hooks/compact-gate done`.
  다음 단위를 시작하면 다시 `busy`. `busy` 재실행은 마커 TTL을 갱신한다.
- 세션이나 요청이 끝나면 반드시 `done`으로 정리한다.
- 상태 확인은 `~/.claude/hooks/compact-gate status` (마커 나이·TTL 잔여 표시).

> 안전장치(약한 것부터): ①경계에서 `done` → ②세션 종료 시 SessionEnd 훅이 마커 정리
> → ③마커 90분 TTL 만료 시 자동 삭제 → ④세션당 연속 미룸 2회 → ⑤컨텍스트 800k 실링.
> 실링은 압축 지점(`autoCompactWindow` 700k → 실효 680k)보다 **위**여야 한다. 아래로 내려가면
> 게이트가 매번 `ceiling-reached`로 즉시 허용해 무력화된다.
> `done`을 빠뜨려도 세션은 죽지 않으며 압축이 최대 2턴 지연될 뿐이다.
> 마커와 미룸 예산 모두 **cwd + session_id 기준**이라 같은 디렉터리에서 여러 세션이
> 돌아도 서로의 작업 단위에 간섭하지 않는다. SessionEnd도 자기 세션 마커만 지운다.
> 수동 `/compact`은 항상 즉시 실행되며 요약 템플릿만 적용된다.

<!-- This text was written straight into ~/.claude/CLAUDE.md, which the next
     `setup.sh sync` regenerates from rules/ + this file — so the sync would have
     deleted it. It lives here because that is the only placement that survives,
     and here rather than rules/ because compact-gate is a Claude Code hook that
     Codex and Antigravity do not have.
     That caveat is now closed: both scripts live in runtimes/claude/hooks/ and
     are listed in manifest.json, so sync symlinks them and wires settings.json
     from the same source this text ships with. Registering them needed the
     manifest's optional `run` field — the default `node "{path}"` cannot express
     a bash hook, an env prefix, or the `sessionend` subcommand. -->

## 실패 명령 원장 — 자동 기록

`rules/70-analysis.md`는 "이미 깨진 것으로 판명된 명령은 `oma-lab fail check`로
먼저 확인한다"고 요구한다. Claude Code에서는 그 기록이 자동이다.
`PostToolUseFailure` 훅(`fail-ledger.js`)이 실패한 Bash 명령을 `oma-lab fail
record`로 남기고, **같은 명령이 트리 변경 없이 다시 실패하면** 이전 실패를
컨텍스트로 돌려준다.

- 첫 실패에는 아무 말도 하지 않는다. 반복일 때만 말한다.
- 명령을 막지 않는다. 이미 실행된 뒤에 도는 훅이다.
- `.oma-lab/`이 있는 repo에서만 기록한다. 그 외 repo에는 상태를 만들지 않는다.
- 끄려면 `OMA_FAIL_LEDGER_HOOK=0`.

트리가 바뀌면 경고로 낮아지므로(수정이 곧 해결일 수 있어서) 재시도는 막히지
않는다. 고친 것이 확실하면 `oma-lab fail resolve --cmd "..."`로 닫는다. 훅은
무엇이 고쳐졌는지 알 수 없어 이것만은 수동이다.

> Codex·Antigravity에는 이 훅이 없다. 그 쪽에서는 `fail check`/`fail record`를
> 직접 호출해야 한다.

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
