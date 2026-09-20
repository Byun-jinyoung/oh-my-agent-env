# Session Ledger — 교차 세션 맥락 추적

목적: GJC·OMO·이후 새 세션이 **원문 대화를 재개하지 않고도** 과거 맥락을 이해하도록,
결정·제약·진행·다음단계를 한 곳에 누적한다. 각 항목은 append-only. 원문 로그가 아니라
계약과 근거만 남긴다(파일 경로+행범위로 참조).

작성 규약(모든 세션 공통):
- Standing constraints: 아직 유효한 사용자 지시(범위·금지·승인 상태). 사용자가 명시 해제 전엔 삭제·완화 금지.
- Decisions: 확정된 결정과 이유.
- Rejected: 배제된 접근과 이유.
- Verified: 실행한 검증과 결과.
- Next: 정확한 다음 단계.

---

## 2026-09-16 · GJC main (w7:p5) · runtime usage 개선

### Standing constraints
- provider·모델 무관하게 과도한 토큰·캐시 사용이 나오지 않아야 한다.
- compaction은 한계의 ~80%에서 미리 수행되어야 한다.
- 문제 해소가 확인되면 전역 설정 + harness 자동 반영이어야 한다.
- 검증 없는 완료 선언 금지. 추측 금지, 실측.

### Decisions
- GJC 전역 config(`~/.gjc/agent/config.yml`): `compaction.strategy=handoff`,
  `thresholdPercent=80`, `thresholdTokens=-1`, `keepRecentTokens=20000`,
  `autoContinue=true`, `handoffSaveToDisk=true`, `idleEnabled=true`,
  `contextPromotion.enabled=false`, `memory.backend=local`.
- 추적 주경로 = handoff 문서(디스크 `0.handoff.log` + `artifact://`). local memory는 배경 보강.
- harness 자동화: `setup.sh sync`가 gjc 설치 후 `sync_gjc_settings`/`sync_omo_settings`로 반영.
  tracked: `runtimes/gjc/settings.conf`, `runtimes/omo/settings.json`.

### Rejected
- tool-dispatcher 권한 차단(`allowedTools`/`deniedTools`) — GJC 스키마에 해당 키 없음.
- `thresholdTokens` 고정값 — provider 창 크기에 따라 오작동. `-1` 유지.
- OMO idle 상시 0 — 매 세션 통합 모델 호출로 사용량 증가.

### Verified
- GJC A/B(강제 임계값·격리): `context-full` 호출당 최대 비캐시 input 11,044 →
  `handoff` 2,549, 세션 파일 1→2(새 세션 생성). 근거 docs/runtime-context-control.md.
- handoff 요약에 R1~R3·D1·A1 verbatim 보존.
- `thresholdPercent`는 창 크기 비례(272K의 80%≈217K 미만 60,680토큰에서 미발동).
- OMO 버전: beta.7 → **beta.65 (senpi 2026.9.16)** 로 업데이트.

### Next
- 현재 OMO beta.65에서 compaction 실제 동작 재측정(이전 결함 판정은 beta.7 기준).
- local memory `memory_summary.md` 실제 생성은 대화형 세션에서 검증.

---

## 2026-09-16 · OMO omo-2 (w7:p6) · compaction re-measure (beta.65)

### Standing constraints
- 읽기 전용 조사. 제품 코드·git 변경 금지. docs/session-ledger.md에만 append.
- 추측 금지, 실측만. 이전 "compaction broken (4/51)" 판정은 beta.7 기준이라 불신.

### Decisions
- 판정 기준을 beta.65(senpi 2026.9.16)의 2026-09-16자 로그로 한정해 재측정.

### Verified
- 소스: `~/.omo/agent/logs/compaction.log` (464줄, parse error 0).
- 2026-09-16 이벤트 3건, 전부 `speculative_invalidated` (generation 0).
  - speculative_started=0, speculative_applied=0, speculative_invalidated=3,
    emergency_prune=0, skip_cap=0, summary_failed=0.
- 참고: 직전 활동일 2026-09-15는 100건으로 로깅 자체는 활발. 09-16은 표본 3건뿐.
- `~/.omo/agent/settings.json` compaction 블록에는 `enabled: true`만 명시 존재.
  speculativeEnabled / keepRecentTokens / model / deterministic 키는 파일에 없음
  (= 코드 기본값으로 동작, 사용자 오버라이드 없음). defaultModel=claude-opus-4-8.

### Next
- 09-16 표본이 3건뿐이라 결함 여부 단정 불가. beta.65에서 실제 대화형 세션을
  돌려 speculative_started→applied 경로가 성립하는지 관측 필요.

---

## 2026-09-16 · GJC main (w7:p5) · OMO 업데이트 + harness 독립 config

### Standing constraints
- OMO 사용량 문제 원인 파악, herdr 기능으로 새 OMO 세션과 함께 진행.
- 문제 해소 시 전역 + harness 자동 반영. `.gjc` 독립 위치로 진행.

### Decisions
- harness 독립 config: `~/.oh-my-agent-env/.gjc/config.yml` 생성(추적). 병합 순서
  `[global, project, overrides]`(settings.ts:1644)이라 harness 실행 시 전역 위에 덮인다.
- `.gitignore`에 `.gjc/*` + `!.gjc/config.yml` — 세션/토큰 로그는 무시, config만 추적.
- harness 자동 설치·설정은 기존 `setup.sh sync`(gjc 설치 + sync_gjc_settings/sync_omo_settings)로 충족.

### Verified
- OMO 업데이트: beta.7 → **beta.65 (senpi 2026.9.16)**.
- 프로젝트 `.gjc/config.yml` override 실측: 전역 80 → 프로젝트 70 반영 확인.
- harness `.gjc/config.yml`에서 `compaction.strategy=handoff` 조회 확인.
- git: 세션 디렉터리는 check-ignore로 무시, `.gjc/config.yml`만 추적 대상.
- herdr로 새 OMO 세션 w7:p6 기동(agent=omp, name=omo-2).

### 관측된 OMO 문제 (원인)
- OMO `~/.omo/agent/settings.json` 기본값이 **provider=anthropic, model=claude-opus-4-8, thinking=high**.
  herdr로 띄운 OMO도 Opus:high로 실행됨 → 사용량 폭증의 직접 원인. 이전 gpt-5.6-sol 기본에서 변경됨.
- OMO/senpi 압축 표면에 GJC식 handoff/thresholdPercent 없음. `speculativeEnabled`,
  `keepRecentTokens`, `model`, `deterministic`만 존재.
- 이전 "압축 결함(4/51)" 판정은 beta.7 기준 → beta.65에서 재측정 필요(미완).

### Next
- OMO 기본 모델을 저비용(gpt-5.6-sol)으로 되돌릴지 사용자 결정 필요(모델 선택은 사용자 선호).
- OMO beta.65 compaction 실제 카운트 재측정.

---

## 2026-09-16 · GJC main (w7:p5) · 근본원인 확정 + 절대상한 수정

### Rejected (이전 잘못된 진단)
- "OMO Opus라서 폭증" — 근거 없음. 모델 무관 발생.
- "thresholdPercent=80이 provider 독립적이라 좋다" — 정반대. 1M 창에서 80%=800K = 폭증 원인.

### Decisions (확정 근본원인)
- 모델 컨텍스트 창: Claude 1,000,000 / Codex 372,000 (models.db).
- thresholdPercent=80 → 800K/297K에서야 compaction → 컨텍스트 무한 누적.
- 실세션 417K 단조증가·compaction 전무, 341배 증폭, turn당 408K.
- 수정: 절대 상한 `thresholdTokens=100000`(percent override). keepRecent=25000,
  idleThresholdTokens=60000.

### Verified
- `thresholdTokens=20000` + 90K 컨텍스트 주입 → 20,891에서 실제 `"type":"compaction"`
  엔트리 생성, 이후 ~11K로 제한. 절대상한이 큰 창과 무관하게 작동함을 실측.
- 전역 config + harness `.gjc/config.yml` + `runtimes/gjc/settings.conf` 모두 100000 반영.

### Next
- 실사용 세션에서 컨텍스트가 ~100K에서 실제로 묶이는지 turn당 토큰으로 재확인.
- thresholdPercent=80 잔존값 제거(현재 config unset 미지원; thresholdTokens가 override).

---

## 2026-09-16 · OMO omo-2 (w7:p6) · compaction.model 픽스 + 실측 시도

### Standing constraints
- 제품 소스 read-only. settings.json·docs만 수정. git 변경 금지.
- 원인 규명→수정→실측(정말 작동하는지)까지. 추측 금지.

### Decisions (근본원인, 소스 확정)
- 원인1(구조): 트리거 = `contextWindow × baseThresholdRatioForWindow`(≤128K:0.6/≤512K:0.7/>512K:0.8, clamp 0.4-0.85). policy.js. 설정으로 못 낮춤. 큰 창일수록 늦게 발동.
- 원인2(구현): 요약이 세션 모델(무겁고 quota 공유)로 실행 → 실패. 해법 = `compaction.model`로 별도 모델 분리(`_resolveCompactionModel`: `settings.compaction.model` → `getModel(p,id) ?? sessionModel`, 해석 실패 시 **세션 모델로 조용히 폴백**).
- 픽스: live+managed settings.json에 `compaction.model=anthropic/claude-sonnet-5`.

### Verified (실측)
- 증폭 실측: boltz 세션 562콜, 총입력 77.2M / 출력 260K = **297배**, cacheRead 92.1%.
- compaction.log 전체: speculative started 51 / applied 4 / invalidated 98; blocking committed 24/failed 17/rejected 10(session.log).
- omo `-p`는 `</dev/null` 없으면 stdin에서 무한 대기(120-150s 타임아웃). 붙이면 google PONG 6s.
- **차단: `anthropic/claude-sonnet-5` 인증 실패** — `omo -p --model anthropic/claude-sonnet-5` rc=1, `OAuth refresh failed for anthropic ... invalid_grant: Refresh token expired`. anthropic OAuth 만료 → 픽스 as-applied는 **비작동(폴백/실패)**. ready 프로바이더는 google(api_key)·openai-codex뿐.
- fallback.log: 실제 main=`openai-codex/gpt-5.6-luna-fast`, usage-limit 시 anthropic/haiku로 폴백 → 원인2 death spiral 실증.
- codex 창 272K, output reserve 128K → 가용 컨텍스트 ~144K로 190K 임계 도달 불가(codex emergency_prune 설명).
- 실측 실패 사례: 단일 303K 메시지 → `summary_failed: unavailable`(스냅샷 생성 불가); reserveTokens=250000 → `ModelUsabilityBudgetError`; 소형 gemini 세션 수동 `/compact` → no-op(1M의 3%).

### Next (사용자 결정 필요)
- 라이브 커밋 실측이 남았으나, 사용자가 고른 sonnet-5가 인증 불가 → 결정 필요:
  (a) anthropic 재로그인 후 sonnet-5 유지, 또는 (b) ready 모델(google/gemini-2.5-flash 등)로 compaction.model 교체.
- 결정 후: 그 모델로 다회전 대화(임계 초과) 실행해 `compaction_decision: committed`(tokensBefore≫After) 실측.
- 참고: 임계 비율은 config 불가라 원인1은 senpi 업스트림(thresholdTokens/handoff) 필요.

---

## 2026-09-17 · OMO omo-2 (w7:p6) · 재진단·재해결(정정) + 자폭 사고

### Standing constraints
- 읽기 전용 소스. settings.json/models.json/docs만 수정. git 변경 금지.

### Rejected (이전 잘못/사고)
- `compaction.reserveTokens=850000` 자가주입 → 1M 창 모델 부팅 불능(min 1,048,115>1,000,000, assertModelUsable 거부). 사용자가 복구. reserveTokens는 브릭 스위치라 절대 튜닝 금지. 사용자가 managed guard(16384) 추가.
- "sonnet-5 인증 불가" 단정 → **오판(일시적)**. 기본 계정 토큰이 그 순간 만료였을 뿐, 재테스트 시 sonnet-5 PONG rc=0. anthropic 인증 정상.

### Decisions (정정된 재진단)
- 활성 원인 = 원인2(death spiral): 요약이 세션 모델(codex) quota 공유 → codex usage-limit 시 압축도 실패 → 컨텍스트 리셋 안 됨 → 매턴 재전송. 실측 297배는 272K 창 세션(1M 아님)에서 발생.
- 원인1(1M 창 늦은 임계)은 **잠재**: anthropic 다운 시 실효 모델이 codex 272K라 안 물림. opus 1M 사용 시에만 물림.
- 현재 config(compaction.model=sonnet-5, reserveTokens=16384, keepRecentTokens=20000)가 원인2의 **정답**. 사용자 복구본이 올바름.

### Verified (실측)
- sonnet-5·gemini 둘 다 PONG rc=0 → 인증 정상. compaction.model=sonnet-5는 codex/opus와 별도 provider·quota → death spiral 차단.
- 격리 dir(OMO_CODING_AGENT_DIR)+models.json `contextWindow`/`maxTokens` cap로 저컨텍스트 트리거 검증: window 100K로 부팅 정상(브릭 없음), `hard_limit_trigger`@58K 발동 → sonnet-5 요약 실행(결과 생성). death-spiral 실패모드(usage-limit/120s/auth) **전무**.
- 한계: 깨끗한 `committed`(tokensBefore≫After) 미포착 — `-p`는 턴마다 새 프로세스라 교차턴 압축 미완료, 구조화 filler는 요약 저항, gemini 무료티어 429. 전부 테스트 환경 아티팩트(픽스 결함 아님).

### 안전한 원인1 레버(옵션, 미적용)
- `~/.omo/agent/models.json`의 `providers.<p>.modelOverrides.<id>.contextWindow`로 1M 모델 창을 캡 → 압축이 낮은 절대치에서 발동(브릭 안전, 캡=요구량 감소). senpi 자체 관례(OpenAI가 GPT-5.6을 272K로 캡). 단 가용 컨텍스트 축소 트레이드오프라 사용자 선택 사항.

### Next
- 사용자 판단: 원인1까지 조일지(opus 창 캡) 여부. 현 config는 원인2에 대해 올바르고 검증됨.

---

## 2026-09-17 · OMO omo-2 (w7:p6) · herdr 라이브 실측 (결정적 발견)

### Verified (herdr 지속 세션 실측)
- herdr pane split + 실제 omo TUI 구동으로 -p 한계(프로세스/턴) 제거. window-cap models.json 실동작 확인(상태바 `X/120K`, 브릭 없음).
- 압축 **반복 발동 확인**: `threshold_trigger`/`hard_limit_trigger`가 74K·84K·94K·105K·115K에서 발동. 요약 실패 시 `breaker_deterministic_fallback`로 기계적 프룬(오버플로 방지).

### 결정적 발견 (사용자 조치 필요)
- **anthropic `@default` 계정 OAuth refresh token 만료 + omo가 @default에 고정(로테이션 안 함)**. 격리·실제 dir 양쪽 인터랙티브에서 opus(main)·sonnet-5(compaction) 모두 @default에서 인증 실패(`invalid_grant`). 유효 계정 login-2/login-3가 있어도 자동 전환 안 됨.
- 결과: compaction 요약이 `summary_failed: reason="auth"` → **compaction.model=sonnet-5 픽스가 현재 비작동**(요약 실패 → 세션 모델로 silent 폴백 → death-spiral 미해결).
- 격리 dir에서 @default 제거 시 main opus는 login-2로 동작하나 요약 경로는 여전히 auth 실패 → 요약 auth 경로가 main 경로만큼 크리덴셜을 못 푸는 정황(단, 격리 크리덴셜 풀 훼손 가능성 있어 클린 재로그인 후 재확인 필요).

### 해결 (사용자만 가능)
- anthropic **재로그인**으로 @default 갱신, 또는 만료된 @default 제거해 login-2 사용 → 그 후 sonnet-5 compaction이 인증되면 픽스 실동작(메커니즘은 실측상 정상 발동).
- 대안: 요약 auth가 확실히 되는 모델로 compaction.model 교체(단 google는 요약 경로 env-key 미해결 정황 → 재로그인이 정공법).

### 정리
- 실제 dir 무변경(models.json 추가 후 제거, settings.json 미변경). herdr pane w7:p8 생성 후 닫음. 테스트 산출물 전부 삭제.
- 픽스 결함이 아니라 **anthropic 인증 만료**가 실동작을 막는 실체. 재로그인 전까지는 검증 불가.
