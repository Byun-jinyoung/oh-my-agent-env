# Claude Code — tool guidance

<!-- Layer B: Claude-only, appended to the shared rules/*.md by sync. Layer A is
     read by three CLIs, so it is not cut on Claude-only evidence; this file is.

     What was measured before cutting (234 tool-using sessions, transcripts):

       ctx_* (context-mode)  103 sessions  44.0%   PreToolUse hook routes it
       rtk                    12 sessions   5.1%   PreToolUse hook rewrites it
       graphify               11 sessions   4.7%   prose only
       oma-lab                 9 sessions   3.8%   prose only
       compact-gate            5 sessions   2.1%   partly hooked; busy/done manual
       serena                  3 sessions   1.3%   prose only, prescribed twice

     The one thing with a hook behind it is the only one above 5%. That does not
     say prose is worthless, but it does say prose ABOUT a hook is documentation,
     not mechanism — so the rationale below moved into comments like this one.
     Comments cost nothing: the runtime strips them before the file reaches the
     model (verified — the block that used to sit under 압축 게이트 never appeared
     in context). If that ever stops being true, this file doubles in cost and
     the fix is to move these notes to docs/ instead. -->

Claude Code has hooks. RTK and context-mode are hook-enforced, so most routing
is automatic. Below is only what still needs deliberate behavior.

## 압축 게이트 — 작업 단위 경계에서 압축

- 다단계 작업(ToDo 2개 이상)에 착수하면 `~/.claude/hooks/compact-gate busy "<작업명>"`.
- ToDo 하나를 completed로 바꾸는 시점(=작업 단위 경계)에 `~/.claude/hooks/compact-gate done`.
  다음 단위를 시작하면 다시 `busy`. `busy` 재실행은 마커 TTL을 갱신한다.
- 세션이나 요청이 끝나면 반드시 `done`으로 정리한다.
- 상태 확인은 `~/.claude/hooks/compact-gate status`.

<!-- 무엇을 막는가: auto-compact이 작업 도중에 터져 맥락이 끊기는 것. PreCompact
     훅이 마커를 보고 압축을 미룬다.

     안전장치(약한 것부터): ①경계에서 `done` → ②세션 종료 시 SessionEnd 훅이 마커
     정리 → ③마커 90분 TTL 만료 시 자동 삭제 → ④세션당 연속 미룸 2회 → ⑤컨텍스트
     800k 실링. 실링은 압축 지점(`autoCompactWindow` 700k → 실효 680k)보다 **위**여야
     한다. 아래로 내려가면 게이트가 매번 `ceiling-reached`로 즉시 허용해 무력화된다.
     `done`을 빠뜨려도 세션은 죽지 않으며 압축이 최대 2턴 지연될 뿐이다.
     마커와 미룸 예산 모두 cwd + session_id 기준이라 같은 디렉터리에서 여러 세션이
     돌아도 서로의 작업 단위에 간섭하지 않는다. SessionEnd도 자기 세션 마커만 지운다.
     수동 `/compact`은 항상 즉시 실행되며 요약 템플릿만 적용된다.

     이 텍스트가 rules/ 가 아니라 여기 있는 이유: compact-gate는 Claude Code 훅이고
     Codex·Antigravity에는 없다. 두 스크립트는 runtimes/claude/hooks/ 에 있고
     manifest.json에 등록돼 sync가 심링크와 settings.json 배선을 함께 한다.
     manifest의 선택적 `run` 필드가 필요했다 — 기본 `node "{path}"` 로는 bash 훅,
     env prefix, `sessionend` 서브커맨드를 표현할 수 없다. -->

## 실패 명령 원장

실패한 Bash 명령은 `PostToolUseFailure` 훅이 자동 기록한다. 반복 실패일 때만 말을
건다. 고친 것이 확실하면 `oma-lab fail resolve --cmd "..."` — 훅은 무엇이 고쳐졌는지
알 수 없어 이것만 수동이다.

<!-- rules/70-analysis.md 는 "이미 깨진 것으로 판명된 명령은 oma-lab fail check로
     먼저 확인한다"고 요구한다. Claude Code에서는 그 기록이 자동이라 확인도 자동으로
     돌아온다: fail-ledger.js 가 실패를 `oma-lab fail record`로 남기고, 같은 명령이
     트리 변경 없이 다시 실패하면 이전 실패를 컨텍스트로 돌려준다.
     - 첫 실패에는 아무 말도 하지 않는다.
     - 명령을 막지 않는다. 이미 실행된 뒤에 도는 훅이다.
     - `.oma-lab/`이 있는 repo에서만 기록한다. 그 외 repo에는 상태를 만들지 않는다.
     - 끄려면 `OMA_FAIL_LEDGER_HOOK=0`.
     트리가 바뀌면 경고로 낮아지므로(수정이 곧 해결일 수 있어서) 재시도는 막히지 않는다.
     Codex·Antigravity에는 이 훅이 없어 그 쪽에서는 fail check/record를 직접 부른다. -->

## context-mode

PreToolUse 훅이 토큰이 큰 명령을 자동 라우팅한다. 남는 것은 **Think in Code**:
데이터를 분석·집계·필터·파싱할 때는 `ctx_execute(language, code)`로 코드를 써서
답만 출력한다 — 원본을 컨텍스트로 끌어오지 않는다. `ctx_batch_execute`는 여러
명령과 검색을 한 번에, `ctx_fetch_and_index(url, source)`는 웹 문서용.

<!-- `/clear`·`/compact` 후에도 knowledge base는 유지된다. 초기화는 `ctx purge`. -->

## RTK

훅이 토큰이 큰 명령을 투명하게 재작성한다(`git status` → `rtk git status`).
수동 접두는 필요 없다. 직접 부를 것은 메타 명령뿐: `rtk gain`(절감량),
`rtk gain --history`, `rtk discover`, `rtk proxy <cmd>`(필터 없이 원본 실행).

<!-- `rtk gain`이 실패하면 reachingforthejack/rtk(Rust Type Kit)와 이름 충돌일 수
     있다. `which rtk`로 확인. -->

## Skills

사용자가 `/graphify`라고 치면 다른 것보다 먼저 Skill 도구를 `skill: "graphify"`로
호출한다.

<!-- 설치된 스킬 목록은 여기 두지 않는다: 런타임이 매 세션 전체 목록을 이미 주입하고
     있고(graphify, codebase-scan, triangle-review, slurm-hpc, spec-interview,
     git-cli-workflow, multi-agent-review 모두 그 목록에 있다), 같은 이름을 두 번
     싣는 것은 컨텍스트만 쓰고 아무것도 더 알려주지 않는다. 목록은
     registry.yaml 이 SSOT이고 sync가 ~/.claude/skills/ 로 내린다.

     graphify-out/ 이 있는 프로젝트의 사용법도 여기서 뺐다 — lib/common.sh:594 의
     append_section_if_missing 가 그 프로젝트의 CLAUDE.md 에 같은 내용을 직접 넣기
     때문에, 전역 사본은 해당 프로젝트에서 중복이고 나머지 프로젝트에서는 무관하다. -->
