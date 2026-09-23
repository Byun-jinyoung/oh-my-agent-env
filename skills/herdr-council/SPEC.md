# Herdr Council Specification

## 1. 문서 목적

이 문서는 `herdr-council`의 기능 목표, 사용자 의도, 실행 계약, 안전 경계, 배포 및 검증 기준을 정의한다. 최초 설계 논의부터 workflow-isolation 보정까지 현재 세션에서 확정된 결정을 통합한 구현 기준이다.

`herdr-council`은 기존 workflow skill을 묶어 호출하는 wrapper가 아니다. Herdr workspace에서 여러 coding-agent session이 동일한 문제를 독립적으로 추론하고, 서로 직접 논의하며, evidence를 기준으로 결론을 조정하는 독립적인 companion workflow다.

## 2. 목표

- 여러 runtime의 AI가 동일한 조사·설계·검토 문제를 각각 독립적으로 분석한다.
- 독립 결론을 고정한 뒤 Herdr를 통해 AI끼리 직접 질문하고 반론한다.
- 다수결이 아닌 evidence의 직접성·재현성·관련성을 기준으로 결론을 reconcile한다.
- 구현 단계에서만 파일·모듈·interface·검증 ownership을 분담한다.
- orchestration session 하나가 전체 과정을 통제하고 사용자에게 최종 결과를 취합해 보고한다.
- 기존 session과 council이 생성한 session을 지속 가능한 작업 공간으로 보존한다.
- 기본 `herdr` skill의 CLI 지침과 분리된 재사용 가능한 workflow skill로 제공한다.

## 3. 비목표

- 기본 `herdr` skill 또는 `herdr --skill` 내용을 복제하거나 대체하지 않는다.
- 일반적인 단일-agent 작업을 자동으로 council 작업으로 변경하지 않는다.
- 사용자 승인 없이 council session을 생성하거나 기존 session에 prompt하지 않는다.
- 조사·설계·검토를 runtime별 lens나 역할로 분할하지 않는다.
- unrestricted all-to-all debate를 제공하지 않는다.
- majority voting으로 결론을 결정하지 않는다.
- 기존 workflow skill의 source, trigger, registry 또는 production 상태를 변경하지 않는다.
- 기존 `spec-interview` 또는 `multi-agent-review`를 호출하거나 dependency로 사용하지 않는다.
- 사용자가 요청하지 않은 repository council artifact를 생성하지 않는다.

## 4. 핵심 용어

| 용어 | 정의 |
|---|---|
| Orchestration session | 최초 사용자 요청을 받고 council 전체를 통제하며 최종 보고를 담당하는 session |
| Participant | 사용자가 승인한 council roster에 포함된 AI session |
| Context pack | 모든 participant에게 동일하게 전달하는 frozen 입력 |
| Independent reasoning | 다른 participant의 결론을 보기 전에 동일한 전체 문제를 독립 분석하는 단계 |
| Direct discussion | participant가 Herdr agent targeting으로 지정된 상대에게 직접 질문·반론하는 단계 |
| Reconciliation | evidence를 기준으로 주장과 이견의 최종 상태를 결정하는 단계 |
| Implementation ownership | 합의된 설계 이후 코드 구현 범위를 session별로 분담하는 것 |

## 5. 호출 정책

### 5.1 지원하는 호출

다음 요청을 council 요청으로 인식한다.

- 사용자가 `herdr-council`을 명시한다.
- 사용자가 Herdr에서 여러 AI가 논의·교차 검증·reconcile하도록 명시한다.
- 사용자가 Claude Code, Codex, GJC, OMO 등의 session을 지정하여 동일 문제를 논의하도록 요청한다.
- orchestration session이 council 사용을 제안하고 사용자가 승인한다.

자연어와 경량 구조화 입력을 모두 지원한다.

```text
herdr-council
agents: codex,gjc,omo
focus: architecture
rounds: 2
```

이는 엄격한 command grammar가 아니라 해석 가능한 요청 형식이다.

### 5.2 제안과 실행의 구분

- reasoning-heavy 작업에서 orchestration session은 council 사용을 제안할 수 있다.
- 제안은 session 생성이나 prompt 권한이 아니다.
- 사용자가 명시적으로 council을 요청하지 않았다면 roster와 process를 제안한 뒤 승인을 기다린다.
- 사용자가 council을 명시했고 목표·scope·constraints·roster가 명확하면 preflight 보고 후 별도 승인 반복 없이 진행할 수 있다.
- 중요한 `Unknown`이 있으면 사용자 답변 전 session을 제어하지 않는다.

### 5.3 과잉 감지 금지

다음 요청만으로 council을 자동 실행하지 않는다.

- 일반적인 기능 구현 요청
- 단순한 코드 검토 요청
- 고위험 변경이라는 agent 자체 판단
- 여러 관점이 유용할 것 같다는 agent 자체 판단
- 다른 workflow에 존재하는 자동 trigger 조건

## 6. 필수 Preflight

Session 생성·재사용·prompt 전에 orchestration session은 다음을 보고한다.

```text
Interpreted Intent
Known
Unknown
Needs Verification
Excluded
Proposed Council
Proposed Process
```

### 6.1 처리 규칙

- 관찰한 사실과 가정을 분리한다.
- 검증되지 않은 가정을 `Known`으로 올리지 않는다.
- 결과를 바꿀 수 있는 `Unknown`은 사용자에게 질문한다.
- 사용자가 intent 해석이 틀렸다고 하면 즉시 중단하고 의도를 다시 확정한다.
- 제한적인 read-only 조사는 preflight 전에 수행할 수 있다.
- 조사 중 사용자 해석이 필요한 지점에 도달하면 추가 조사를 중단한다.
- `Excluded`에는 이번 council이 다루지 않을 기능·파일·workflow를 명시한다.

## 7. Council 구성

### 7.1 사용자 지정 우선

- 참여 runtime과 session 수는 사용자가 최종 결정한다.
- 사용자가 지정한 session과 runtime을 우선한다.
- 고정된 기본 session 수를 두지 않는다.
- 사용자가 roster를 지정하지 않으면 orchestration session이 roster, session 재사용 여부, 새 session 필요 여부, 예상 discussion round를 제안하고 승인을 기다린다.

### 7.2 Session 탐색과 재사용

- 현재 Herdr workspace의 다른 tab까지 탐색할 수 있다.
- 사용자가 지정한 적절한 idle session을 우선 재사용한다.
- working 또는 blocked session을 침범하지 않는다.
- 다른 workspace의 session은 사용자가 지정한 경우에만 사용한다.
- 적절한 session이 없으면 focus를 빼앗지 않고 새 session을 만든다.
- runtime이 native `herdr agent start` kind가 아니면 구성된 launcher를 사용한다.
- participant마다 Herdr 직접 통신에 사용할 안정적인 고유 이름을 부여한다.

### 7.3 Session 수명

- 기존 session을 자동 종료하지 않는다.
- 이번 council에서 생성한 session도 자동 종료하지 않는다.
- 후속 조사·설계·구현·검토에 재사용할 수 있다.
- session 종료는 사용자가 명시적으로 지시한 경우에만 수행한다.

## 8. 역할과 독립성

### 8.1 조사·설계·검토

역할을 분해하지 않는다.

- 모든 participant가 동일한 전체 문제를 독립적으로 조사한다.
- 모든 participant가 전체 설계를 독립적으로 작성한다.
- 모든 participant가 전체 결과를 독립적으로 검토한다.
- 다른 participant의 결론을 보기 전에 자신의 결론을 고정한다.
- 동일 문제에 대한 독립 분석은 의도된 cross-validation이며 제거할 중복이 아니다.

다음 방식은 금지한다.

- Claude는 사용자 의도, Codex는 correctness, GJC는 integration처럼 reasoning lens를 미리 분담하는 것
- 한 participant에게 전체 문제의 일부만 분석시키는 것
- 최초 participant의 결론을 다른 participant의 출발점으로 제공하는 것

### 8.2 구현

구현 단계에서만 역할과 ownership을 분담한다.

- 파일, 모듈, interface 또는 검증 책임으로 범위를 나눈다.
- 병렬 구현 전에 공유 계약을 확정한다.
- 겹치는 write surface에는 owner를 하나만 둔다.
- 동일 파일을 두 session이 동시에 수정하지 않는다.
- 각 구현 session에는 reconciled decision과 자신의 제한된 assignment만 전달한다.
- orchestration session이 변경 union을 통합하고 cross-cutting verification을 실행한다.

## 9. Workflow isolation

### 9.1 기본 규칙

- 사용자가 해당 workflow를 명시적으로 요청하지 않는 한 다른 workflow skill을 호출하거나 의존하지 않는다.
- 다른 skill에서 유용한 reasoning principle을 발견해도 그 skill을 실행할 권한으로 해석하지 않는다.
- 필요한 원칙은 `herdr-council` 내부 계약에 맞게 adaptive copy하고 원본 workflow로 chain하지 않는다.
- isolation 규칙은 orchestration session과 모든 participant에 적용한다.
- participant는 추가 workflow skill을 호출하지 않는다.
- participant는 사용자 승인 roster 밖의 agent를 생성하거나 delegate하지 않는다.
- scope 확장이 필요하다고 판단하면 orchestration session에 finding으로 반환한다.

### 9.2 Adaptive copy 허용 범위

허용한다.

- 사용자 intent, scope, constraint, unknown을 구분하는 원칙
- 중요한 ambiguity를 실행 전에 해결하는 원칙
- claim에 evidence를 요구하는 원칙
- 독립 검토 및 confidence 보고 형식
- orchestration session이 최종 판단과 보고를 소유하는 원칙

허용하지 않는다.

- 원본 workflow skill 실행
- 원본 workflow를 runtime dependency로 참조
- 원본 workflow의 파일 mutation 부수효과 복사
- reasoning 단계의 역할·lens 분담 복사
- adaptive-copy 출처를 runtime 관계나 dependency처럼 노출

### 9.3 기존 스킬과의 경계

`spec-interview`와 `multi-agent-review`는 이번 기능 구현 이전부터 존재한 별도 skill이다.

- 두 skill은 `herdr-council` 구성 요소가 아니다.
- 두 skill의 source, trigger, registry, 배포 상태를 이번 작업에서 변경하지 않는다.
- 두 skill의 production 수준이나 존폐를 이번 Spec에서 판단하지 않는다.
- 사용자가 별도로 요청하지 않는 한 council이 두 skill을 호출하지 않는다.

### 9.4 복합 Workflow 요청

사용자가 `herdr-council`과 다른 workflow를 모두 명시한 경우:

- 실행 순서와 handoff가 명확하면 사용자 요청대로 수행한다.
- 순서나 산출물 전달 방식이 결과에 영향을 주면서 불명확하면 먼저 질문한다.
- 각 workflow의 lifecycle과 산출물을 구분한다.
- orchestration session이 명시되지 않은 결합 방식을 임의로 만들지 않는다.

## 10. Phase 0 — Frozen context pack

Orchestration session은 공통 사실을 한 번 정리하고 모든 participant에게 동일하게 전달한다.

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

`Workflow boundary`에는 최소한 다음을 포함한다.

```text
- Use only the approved herdr-council protocol.
- Do not invoke another workflow skill.
- Do not create or delegate to agents outside the approved roster.
- Return proposed scope expansion to the orchestration session.
```

`Language boundary`에는 최소한 다음을 포함한다.

```text
- Use English for all inter-session communication (context packs, prompts,
  independent conclusions, direct questions and rebuttals, reconciliation
  messages, and implementation handoffs).
- Communicate only with the orchestration session or explicitly approved peers.
- Only the orchestration session communicates directly with the user, in Korean.
```

공통 repository mapping이나 이미 확인된 사실을 각 participant에게 반복 조사시키지 않는다. 단, 각 participant는 그 사실을 포함한 전체 문제를 독립적으로 평가한다.

## 11. Phase 1 — 독립 추론

각 participant는 이 phase를 포함한 모든 inter-session communication을 영어로 수행한다. 각 participant는 다음 형식으로 동일한 전체 문제에 답한다.

```text
Claims
Evidence
Risks
Open questions
Proposed decision
Confidence and reasons
```

중요 claim에는 다음 중 하나 이상의 evidence handle이 필요하다.

- 파일과 line
- command output
- test 결과
- 공식 문서
- 재현 절차
- 명시적인 논리 전제

모든 가능한 독립 결과가 고정되기 전에는 participant에게 peer의 결론을 노출하지 않는다.

## 12. Phase 2 — Herdr 직접 논의

### 12.1 Hybrid topology

Moderated 방식과 direct 방식의 장점을 결합한다.

- orchestration session이 충돌 쟁점, 상대, discussion 범위를 지정한다.
- participant는 Herdr agent targeting으로 지정된 상대에게 직접 질문·반론한다.
- orchestration session은 단순 중계로 직접 논의를 대체하지 않는다.
- unrestricted direct mesh는 허용하지 않는다.

### 12.2 Peer response 형식

```text
Agreements
Challenges
Missing evidence
Changed conclusions
Remaining disagreements
```

direct question, rebuttal을 포함한 모든 peer-to-peer discussion은 영어로 진행한다. Participant는 orchestration session 또는 사용자가 승인한 peer 외에는 통신하지 않는다.

### 12.3 Discussion 한계

- 한 쟁점은 기본 두 번의 직접 왕복으로 제한한다.
- 추가 round에는 새로운 evidence 또는 더 명확한 falsifiable argument가 필요하다.
- 새로운 evidence 없이 같은 주장을 반복하지 않는다.
- 이미 합의된 쟁점은 새로운 evidence가 결론을 무효화하지 않는 한 다시 열지 않는다.
- participant는 reasoning 중 product file을 수정하지 않는다.
- participant는 추가 agent를 생성하거나 구현을 delegate하지 않는다.

## 13. Phase 3 — Reconciliation

Reconciliation message는 영어로 작성한다. 각 material issue를 하나의 claim으로 관리한다. 동일 finding을 여러 항목으로 부풀리지 않고 confirmation과 challenge를 같은 항목에 추가한다.

허용 상태:

| 상태 | 의미 |
|---|---|
| `AGREED` | 기존 결론에 합의 |
| `REVISED` | discussion 후 결론 수정 |
| `EVIDENCE_NEEDED` | 추가 evidence가 필요 |
| `DEBATE_PERSISTED` | 중요한 이견이 계속됨 |

### 13.1 판정 기준

- 다수결을 사용하지 않는다.
- evidence의 직접성, 재현성, 관련성, 계약 권위를 평가한다.
- orchestration session은 evidence가 명확한 낮은 위험 이견을 결정할 수 있다.

다음 이견은 사용자에게 escalation한다.

- architecture, API, data 또는 security 결정
- 되돌리기 어려운 변경
- 사용자 선호가 결과를 결정하는 선택
- 서로 충돌하는 evidence가 모두 유효한 경우
- evidence를 재현할 수 없는 경우
- `DEBATE_PERSISTED`가 최종 행동을 바꾸는 경우

## 14. Evidence 관리

### 14.1 간단한 Council

Herdr pane history를 evidence 기록으로 사용한다.

### 14.2 복잡한 Council

참여 session이나 충돌 쟁점이 많고 여러 reconciliation round가 필요한 경우 repository 밖, 기본적으로 `/tmp` 아래 임시 ledger를 사용한다.

```text
ID | Topic | Claim | Author | Evidence | Challenges | Status | Resolution
```

사용자가 요청하지 않는 한 repository에 council ledger나 transcript를 만들지 않는다.

## 15. Phase 4 — 구현

- Reconciliation이 완료되고 필요한 구현 승인이 확보된 뒤 시작한다.
- 구현 작업만 ownership에 따라 분할한다.
- 기존 council session을 구현에 재사용할 수 있다.
- 구현 session도 작업 후 자동 종료하지 않는다.
- orchestration session이 전체 변경을 통합하고 최종 검증한다.
- Implementation handoff(구현 assignment 전달)도 영어로 작성한다.

## 16. 최종 보고

최종 결과는 orchestration session만 사용자에게 보고한다. Participant는 경쟁하는 개별 최종 보고를 사용자에게 제출하지 않는다. Orchestration session은 사용자에게 직접 통신하는 유일한 session이며, 이 최종 보고를 포함한 모든 사용자 대상 메시지는 한국어로 작성한다. 그 근거가 된 council 내부의 독립 추론, 직접 논의, reconciliation은 영어로 진행된 것이어도 최종 보고 자체는 한국어다.

기본 구조:

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

- 기본적으로 전체 transcript 대신 핵심 합의, 반론, evidence, 입장 변경을 요약한다.
- 사용자가 요청하면 pane 또는 transcript 위치를 제공한다.
- 최종 판단과 보고 책임은 orchestration session에 있다.

## 17. 중단 조건

다음 조건에서는 council을 시작하거나 계속하지 않는다.

- 현재 session이 Herdr 환경이 아님
- 사용자 intent가 불명확하거나 사용자가 해석을 정정함
- 제안된 council을 사용자가 승인하지 않음
- 사용자 지정 roster를 실행할 수 없고 대체가 의도를 바꿈
- 적합한 session이 모두 working 또는 blocked 상태임
- discussion이 새로운 evidence 없이 반복됨
- 안전한 implementation ownership 경계를 만들 수 없음
- 최종 행동을 바꾸는 `DEBATE_PERSISTED`가 남음
- 다른 workflow 또는 roster 밖 agent가 필요하지만 사용자 승인이 없음

## 18. 기본 Herdr Skill과의 관계

- 기본 `herdr` skill은 CLI 조작법의 source of truth다.
- 기본 skill은 설치된 binary의 `herdr --skill`에서 생성한다.
- `herdr-council`은 CLI 문법을 복제하거나 추측하지 않는다.
- `herdr-council`은 repository가 관리하는 정적 companion workflow다.
- 기본 skill 생성 실패와 council source 배포는 서로 독립적이어야 한다.

## 19. 배포 요구사항

| Runtime | Scan root |
|---|---|
| GJC | `~/.gjc/agent/skills/herdr-council/SKILL.md` |
| Claude Code | `~/.claude/skills/herdr-council/SKILL.md` |
| Codex | `~/.codex/skills/herdr-council/SKILL.md` |
| OMO/pi | `~/.agents/skills/herdr-council/SKILL.md` |

- 네 위치에 외부 symlink가 아닌 실제 `SKILL.md`를 설치한다.
- canonical source는 `skills/herdr-council/SKILL.md`다.
- sync 후 네 배포본은 canonical source와 byte-identical이어야 한다.
- root별 실패를 개별 경고한다.
- 일부 root만 성공한 경우 전체 성공으로 보고하지 않는다.
- directory-shaped `SKILL.md` target을 성공으로 처리하지 않는다.
- doctor는 네 root의 존재와 council source 일치를 검사한다.

## 20. Repository 산출물

| 산출물 | 위치 | 역할 |
|---|---|---|
| Runtime skill | `skills/herdr-council/SKILL.md` | AI가 실행할 workflow 지침 |
| Specification | `skills/herdr-council/SPEC.md` | 사용자 의도와 구현 계약의 기준 문서 |
| Sync implementation | `lib/sync/agent-clis.sh` | Base skill 생성 및 council 4-root 배포 |
| Doctor implementation | `lib/doctor/local-prereqs.sh` | 배포 상태와 source parity 검사 |
| Regression coverage | `tests/smoke-refactor.sh` | 배포·장애·idempotency 회귀 검증 |

## 21. 검증 기준

### 21.1 Workflow 계약

- 조사·설계·검토에서 역할을 분담하지 않는다.
- 모든 participant가 동일한 전체 문제를 독립 추론한다.
- Participant끼리 Herdr로 직접 질문·반론한다.
- Evidence 없는 다수결을 사용하지 않는다.
- 구현 단계에서만 ownership을 분담한다.
- orchestration session만 최종 보고한다.
- 기존·신규 session을 자동 종료하지 않는다.
- 사용자 승인 없이 다른 workflow를 호출하지 않는다.
- roster 밖 agent를 자동 생성하지 않는다.
- Context pack, prompt, 독립 결론, direct question/rebuttal, reconciliation message, implementation handoff를 포함한 모든 inter-session communication이 영어다.
- Participant는 orchestration session 또는 사용자 승인 peer하고만 통신한다.
- orchestration session만 사용자와 직접 통신하며, 그 user-facing 메시지와 최종 보고는 한국어다.

### 21.2 배포 및 회귀

- 네 scan root에 council `SKILL.md`가 존재한다.
- 네 배포본이 canonical source와 일치한다.
- 기본 `herdr --skill` 실패 시에도 council source는 배포된다.
- partial deployment가 false `[OK]`를 만들지 않는다.
- doctor가 네 root와 source drift를 탐지한다.
- sync가 idempotent하다.
- GJC, Codex, OMO에서 skill discovery와 사용을 확인한다.
- Claude Code runtime pilot은 사용량 제약이 지정된 테스트에서는 제외할 수 있지만 scan-root 배포와 source parity는 확인한다.

## 22. 확정된 의사결정 기록

| 주제 | 결정 |
|---|---|
| Workflow 이름 | `herdr-council` |
| 기본 `herdr`와의 관계 | 별도 companion skill |
| 기존 workflow와의 관계 | 호출·dependency 없이 독립 |
| 조사·설계·검토 역할 | 분담하지 않음 |
| 구현 역할 | 구현 단계에서만 분담 |
| Council 구성 | 사용자 지정 우선, 미지정 시 제안 후 승인 |
| Session 범위 | 현재 workspace의 다른 tab까지 탐색, 다른 workspace는 사용자 지정 시에만 사용 |
| Communication | Orchestrator가 통제하는 direct Herdr discussion |
| Reconciliation | Evidence 기반, majority voting 금지 |
| 미해결 이견 | 낮은 위험은 orchestrator 판단, 중요한 결정은 사용자 escalation |
| 최종 보고 | Orchestration session이 취합 |
| Session cleanup | 사용자 명시 지시 없이는 종료 금지 |
| 입력 형식 | 자연어와 경량 구조화 형식 지원 |
| Evidence 기록 | 간단한 작업은 pane, 복잡한 작업은 `/tmp` ledger |
| Workflow isolation | 일반 규칙으로 orchestration session과 모든 participant에 적용 |
| Adaptive copy | 원칙과 결과 형식만 허용 |
| 기존 두 skill | 이번 범위에서 수정·삭제·평가하지 않음 |
| Repository 보정 범위 | Runtime isolation 보정은 `skills/herdr-council/SKILL.md`에 한정 |
| Live 적용 | Source 변경 후 기존 sync로 네 runtime 배포본 갱신 |
| Language policy | Inter-session communication은 token 효율을 위해 영어, orchestration session의 user-facing 통신과 최종 보고만 한국어 |

## 23. 구현 승인 경계

Workflow-isolation 보정 구현은 다음 범위로 제한한다.

1. `skills/herdr-council/SKILL.md`에 일반적인 workflow isolation section을 추가한다.
2. Context pack에 `Workflow boundary`를 포함한다.
3. 특정 기존 workflow 이름을 runtime skill에 추가하지 않는다.
4. 기존 workflow 파일과 registry를 수정하지 않는다.
5. 기존 sync 함수를 사용해 네 runtime 배포본을 갱신한다.
6. Source parity, discovery, Markdown/frontmatter, `git diff --check`를 검증한다.
7. 기존에 push된 commit을 amend하거나 force-push하지 않고 별도 논리 commit으로 처리한다.

권장 commit message:

```text
fix(herdr): isolate council from unrelated workflows
```
