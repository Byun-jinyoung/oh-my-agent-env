# GJC 사용량 제어 — scope/spec API (새 세션용)

컨텍스트 없는 새 GJC 세션이 이 저장소의 **사용량(토큰/컨텍스트) 제어** 기능을 즉시 이해하고
안전하게 이어가기 위한 요약. 정본은 `runtimes/gjc/settings.conf`(추적) → `setup.sh sync`가
`gjc config set`으로 `~/.gjc/agent/config.yml`(GJC 전역 config)에 반영한다. 프로젝트 override 없음.

측정 근거 원문: `docs/runtime-context-control.md`, `docs/session-ledger.md`.

---

## #1 절대토큰 compaction — 비이상적 사용량 증가 차단

### Scope
모델 창(window)이 거대할 때(claude-opus/sonnet = 1,000,000; codex = 372,000) `thresholdPercent`는
창 대비 퍼센트라 800K/297K까지 압축이 안 터진다. 컨텍스트가 수백K로 부풀고 매 턴 전체를
재전송 → 실측 341x 증폭(한 세션 46.5M 토큰 / 136K 출력). provider 무관.

### Spec (config API)
| 키 | 값 | 의미 |
|---|---|---|
| `compaction.thresholdTokens` | `150000` | 절대토큰 임계. 설정 시 `thresholdPercent`를 오버라이드(고정 크기에서 압축) |
| `compaction.keepRecentTokens` | `40000` | 압축 후 보존할 최근 토큰(문서 권장 20000과 괴리 — #2에서 결정) |
| `compaction.idleEnabled` | `true` | 방치 세션을 재개 전 축소 |
| `compaction.idleThresholdTokens` | `100000` | idle 압축 임계 |
| `compaction.enabled` | `true` | compaction 사용 |
| `contextPromotion.enabled` | `false` | overflow 시 대형창 모델 승격 비활성(사용량 증폭 차단) |

`thresholdPercent`(라이브 80)는 `thresholdTokens`가 설정되면 무효.

### 실측 상태
샌드박스 A/B에서 호출당 비캐시 input 11,044→2,549 감소 확인(strategy만 교체).
**주의: 현행 150K 값에서의 실세션 사용량 감소는 재측정 안 됨(육안 확인 대상).**

### 검증
`grep -E 'thresholdTokens|keepRecentTokens|idleThresholdTokens' ~/.gjc/agent/config.yml`
(주의: `gjc config get` stdout은 캐시/옛값 에코 가능 → 반드시 온디스크 config.yml로 검증.)

---

## #3 handoff auto-continue — handoff 후 자동 이어짐

### Scope
GJC 압축은 `strategy=handoff`(작업 경계에서 세션 종료 후 새 세션으로 이어감)로 컨텍스트
무증폭. 그러나 auto-continue 판정 `#ru()`는 **active goal 또는 열린 todo가 있을 때만** 발동한다.
handoff 산문 문서는 신호가 아니라서 자식 세션이 조용히 멈춘다
(`Auto-continue skipped: no unfinished work detected`). `goal pause`는 즉시 중단 트리거.

### Spec (2계층)
1. **handoffPromptExtension** (`compaction.handoffPromptExtension`): 자식 세션이 handoff 직후
   `goal(create)`/`goal(resume)`로 **active goal을 재-arming**하고, 작업이 남은 동안
   pause/complete 금지, 다음 단계 즉시 진행하도록 지시. "Standing constraints" 절에 사용자 지시·
   결정·거부안을 verbatim 보존.
2. **attitude-gate `todoActive`** (`~/.gjc/agent/hooks/attitude-gate.json`, `enabled:true`):
   mutation(write/edit/bash) 전에 `todo_write` 또는 `goal(create/resume)`를 강제 →
   auto-continue 신호를 항상 살림. 소스 `runtimes/gjc/hooks/pre/_gate.ts`.

| 키/파일 | 값 | 의미 |
|---|---|---|
| `compaction.strategy` | `handoff` | 컨텍스트 무증폭 이어가기(context-full/off 회귀 금지 — 341x 재발) |
| `compaction.autoContinue` | `true` | handoff 후 새 세션 자동 생성·이어감 |
| `compaction.handoffSaveToDisk` | `true` | handoff 문서 디스크 저장 |
| `attitude-gate.json.gates.todoActive` | `true` | mutation 전 goal/todo 강제 |

### 새 세션 필수 행동
handoff로 뜬 자식 세션은 **작업 시작 전 `goal(create)` 또는 `goal(resume)`로 active goal을 걸고
목표 끝까지 유지**하라. pause/complete는 auto-continue를 끊는다.

### 실측 상태
로직·설정·훅 배포·config 검증 완료. **긴 실세션 자동이어짐 육안 실증 미완.**

### 알려진 리스크 (미수정)
attitude-gate 훅이 `Extension "<inline-0>" error: handler timed out after 30000ms`로
침묵 실패하면 `todoActive` 강제가 안 걸려 신호 유실 가능. 유력 원인 가설:
`_graft-nudge.ts`의 `execFileSync("graft ask", {timeout:8000})`가 Bun에서 timeout 미강제 →
harness 30s까지 hang. `failClosed:false`라 mutation 자체는 통과.

---

## 공통 적용 경로 (SSOT)
```
runtimes/gjc/settings.conf   (정본, git 추적)
        │  setup.sh sync → sync_gjc_settings (lib/sync/agent-clis.sh)
        ▼
~/.gjc/agent/config.yml      (GJC 전역 라이브 config)
```
훅: `runtimes/gjc/hooks/pre/*.ts` → `sync_gjc_hooks` → `~/.gjc/agent/hooks/pre/*.ts`(hot-reload).

## 하지 말 것
- `strategy`를 `context-full`/`off`로 회귀(341x 재발). 임계값은 "올리는" 조정만.
- `handoffPromptExtension`의 goal-arming 절 제거.
- config 반영을 `gjc config get` stdout으로 판단(온디스크로 검증).
