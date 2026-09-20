# GJC·OMO 컨텍스트 재전송 조사와 작업 지시 계약

작성일: 2026-09-15 (근본원인 확정 2026-09-16)

## ★ 확정된 근본 원인 (2026-09-16, 실측)

비이상적 사용량 폭증의 원인은 **모델 선택이 아니다**(Claude·Codex 모두 발생). 원인은
**컨텍스트 창이 거대한데 compaction 임계값이 그 창의 퍼센트라서, compaction이 너무 늦게
발동해 컨텍스트가 수십만 토큰까지 누적되고 매 turn 전체가 재처리되는 것**이다.

실측 근거:
- 모델 컨텍스트 창(`~/.gjc/agent/models.db`): claude-opus-4-8 / claude-sonnet-5 = **1,000,000**,
  gpt-5.6-terra / gpt-5.6-sol = **372,000**.
- `compaction.thresholdPercent=80`은 창의 80%에서 발동 → Claude **800,000** / Codex **297,600**.
- 실세션(01a0a26e): 컨텍스트가 **417,475 토큰까지 단조 증가, compaction 전무**
  (800K 미도달과 일치). 114 turn · 46.5M 총 토큰 · 출력 136K = **341배 증폭**, turn당 약 408K.
- 즉 매 turn이 ~400K 컨텍스트를 재처리(cacheRead, 또는 cache miss 시 전량 input)해 ~1,500 토큰을
  출력한다. cacheRead도 5시간/주간 한도에 누적된다.

### 잘못된 이전 진단 2건 (철회)
1. "OMO가 Opus라서 폭증" — 근거 없음. 모델 무관하게 발생.
2. "thresholdPercent=80이 provider 독립적이라 좋다" — **정반대**. 1M 창에서 80%는 800K로,
   폭증의 원인 그 자체다.

### 수정 = 절대 토큰 상한
`compaction.thresholdTokens`는 "overrides percentage if set"(schema)이라, 창 크기와 무관하게
고정 토큰에서 발동한다. **실측 검증**: `thresholdTokens=20000` + 90K 토큰 컨텍스트 주입 시
20,891에서 **실제 `"type":"compaction"` 엔트리 생성**, 이후 컨텍스트 ~11K로 제한.
따라서 `thresholdTokens=100000`은 Claude 1M 창에서도 컨텍스트를 ~100K로 묶어
현재 417K→800K 궤적 대비 약 4~8배 turn당 비용을 줄인다.

적용값(전역 `~/.gjc/agent/config.yml` + harness `.gjc/config.yml` + 추적 `runtimes/gjc/settings.conf`):
`thresholdTokens=100000`, `keepRecentTokens=25000`, `idleThresholdTokens=60000`,
`strategy=handoff`, `contextPromotion.enabled=false`. (`thresholdPercent`는 thresholdTokens가
무력화하므로 값은 무의미.)

## 범위와 용어

- 이 문서는 2026-09-14~15의 로컬 GJC·OMO 로그에 기록된 provider usage 필드를 정리한다.
- `input`, `output`, `cacheRead`, `cacheWrite`, `totalTokens`는 provider가 기록한 토큰 필드다. 유료 플랜의 실제 한도 차감량이나 과금액과 동일하다고 해석하지 않는다.
- **전체 재전송**은 이전 대화, 지침, 도구 결과를 포함한 대형 컨텍스트를 cache hit 없이 새 input으로 다시 보내는 경우다. 정상적인 연속 세션은 공통 prefix를 cache read로 재사용하고 새 메시지·새 도구 결과만 추가한다.

## 관측 결과

| 런타임 / 세션 | 비영 호출 | input | output | cache read | 총 기록 토큰 | 관측된 문제 |
|---|---:|---:|---:|---:|---:|---|
| GJC 2026-09-14 장기 세션 | 29 | 2,093,775 | 14,206 | 3,331,072 | 5,439,053 | `cacheRead=0` 상태에서 175K~182K input을 반복 제출 |
| GJC 2026-09-15 세션 (01:47 UTC 감사 시점) | 30 | 413,454 | 4,398 | 1,508,608 | 1,926,460 | 81분 공백 뒤 102K~103K input 재전송; 마지막 2회 `cacheRead=0` |
| OMO 2026-09-15 primary 세션 | 10 명시 usage 호출 | 48,064 | 1,176 | 1,611,520 | 1,660,760 | 176K~180K prefix를 cache read로 재사용 |

GJC의 반복된 100K~182K cache-miss input은 비효율적 전체 재전송의 직접 증거다. OMO의 큰 `cacheRead`는 동일 prefix의 재사용과 부합하므로, cache read 숫자만으로 낭비나 유료 플랜 소진량을 단정할 수 없다.

## OMO compaction 상태

OMO의 자동 compaction은 실패와 성공이 섞여 있다.

- 실패 시 원문 컨텍스트가 105K~161K 토큰 규모로 유지됐다. 기록된 실패 이유에는 `empty-summary`와 provider usage-limit 거부가 있다.
- 성공 사례는 130,063→17,068, 110,847→20,057, 162,423→21,345 토큰이다.
- primary 세션에서도 2026-09-15 01:28 UTC에 117,517→21,260 토큰으로 compaction이 성공했다.

따라서 OMO의 문제는 cache read 자체가 아니라, compaction 실패 시 큰 원문 컨텍스트가 계속 유지되는 복구 경로다.

## template 반복과 지시 무시

사용자가 template을 반복한 이유는 정당하다. 반복은 에이전트가 범위, 금지 사항, 검증 기준을 잊거나 무시한 경험에 대한 방어 장치다.

다만 같은 template을 매 turn의 사용자 메시지로 반복하면 컨텍스트가 커진다. GJC가 자연어를 보고 임의로 중복 문장을 삭제해서는 안 된다. 짧은 문구 차이도 우선순위, 승인 조건, 범위를 바꿀 수 있어 의미 기반 제거는 지시 손실을 유발한다.

해결 원칙은 **반복 제거가 아니라 지시의 계층화와 결정적 집행**이다.

1. **불변 계약은 한 곳에 둔다.** 작업 태도, 금지 작업, 검증 기준, 승인 규칙은 프로젝트 지시 파일 또는 런타임의 고정 instruction으로 유지한다. 동일 내용을 매 task prompt에 복사하지 않는다.
2. **각 task prompt는 delta만 둔다.** 목표, 대상 파일/범위, 이번 turn의 승인 상태, 완료 조건만 적는다.
3. **지시를 검증 가능한 계약으로 쓴다.** “신중히 작업” 대신 “`src/a.ts`만 수정, 테스트 X 실행, commit 금지”처럼 대상·행위·판정 기준을 명시한다.
4. **모델의 준수 약속에 의존하지 않는다.** 쓰기·삭제·commit·push처럼 위험한 행위는 CLI 권한, hook, wrapper 또는 CI 정책으로 차단·검증한다. 자연어 지시는 설명과 판단을 위한 층이고, 정책 집행은 결정적 층이다.
5. **작업 경계에서 짧은 handoff로 교체한다.** 세션이 길어지거나 cache miss가 발생하면 원문 transcript를 재개하지 않는다. 아래 handoff만 새 세션에 전달한다.

## 실측: GJC compaction strategy A/B (2026-09-16)

`GJC_CODING_AGENT_DIR`로 격리한 샌드박스에서 동일 워크로드(4개 파일 전체 read)와 동일 임계값(`thresholdTokens: 14000`)으로 strategy만 바꿔 측정했다. 실사용 config는 변경하지 않았다.

| strategy | 호출 | 호출당 최대 비캐시 input | 세션 파일 | 결과 |
|---|---:|---:|---:|---|
| `context-full` (기본값) | 3 | **11,044** | 1 | "Context maintenance could not commit a compaction before the next model request." |
| `handoff` | 5 | **2,549** | 2 | 새 세션 생성, 연속 세션은 빈 상태로 시작 |

핵심은 **호출당 비캐시 input이 11,044 → 2,549로 감소**한 것이다. 전체 재전송 문제의 직접 지표가 이 값이다. `context-full`은 한 세션을 계속 키우다가 압축 커밋에 실패하면 큰 컨텍스트를 그대로 다시 보낸다. `handoff`는 작업 경계에서 세션을 끝내고 새 세션으로 이어간다.

`handoff`의 총 토큰과 cacheRead가 더 큰 것은 호출 수가 더 많았기 때문이며, 그 호출들은 대부분 cache hit다. 비용 측면에서 cache read는 비캐시 input보다 저렴하다.

적용: `runtimes/gjc/settings.conf`(추적) → `setup.sh sync`가 `gjc config set`으로 반영.

### OMO에는 동일 수단이 없다

OMO 설정은 `compaction.enabled` 토글뿐이고 strategy/threshold 항목이 없다. 설치본 `omo 5.0.0-0.beta.7 (senpi 2026.8.12-4)`의 전체 기간 집계는 다음과 같다.

| 이벤트 | 횟수 |
|---|---:|
| speculative_started | 51 |
| **speculative_applied** | **4** |
| speculative_invalidated | 89 |
| emergency_prune | 64 |
| skip_cap | 31 |
| summary_failed (empty-summary) | 10 |

압축 시도 51회 중 적용 4회다. 설정으로 조정할 수 있는 범위가 아니므로 업스트림 업데이트 외에는 해결 수단이 없다.

### 설정으로 강제할 수 없는 것

GJC 설정 스키마에 `allowedTools` / `deniedTools` / `autoApprove`에 해당하는 키는 **없다**. 따라서 도구 권한으로 범위·승인·위험 작업을 차단하는 방식은 현재 버전에서 설정만으로 구현할 수 없다. 설치 패키지를 직접 수정하는 방법은 업데이트 시 덮어써지므로 채택하지 않는다.

## 적용한 전역 설정 (2026-09-16, 실측 완료)

아래는 `~/.gjc/agent/config.yml`(GJC **전역** 사용자 config)에 적용했고, `runtimes/gjc/settings.conf`로 추적되어 `setup.sh sync`가 재적용한다. `gjc config set`은 프로젝트 `.gjc/config.yml`을 만들지 않고 전역 파일에 기록함을 확인했다(프로젝트 override 없음 = 모든 프로젝트/세션에 적용).

| 요구 | 키 | 값 | 실측 |
|---|---|---|---|
| provider 무관 과소비 방지 | `compaction.thresholdPercent` / `thresholdTokens` | `80` / `-1` | 창의 80%(272K→~217K) 미만 60,680토큰에서 handoff 미발생 = 창 크기 비례 확인 |
| 한계 100이면 ~80에서 미리 압축 | `compaction.thresholdPercent` | `80` | 위와 동일 근거 |
| cache hit 적정 | `compaction.keepRecentTokens` | `20000` | 정상 세션 cache hit 52.9% 측정 |
| 과소비 증폭 차단 | `contextPromotion.enabled` | `false` | overflow 시 대형 창 모델 승격 비활성 |
| handoff 지시·결정 보존 | `compaction.handoffPromptExtension` | 아래 | 생성된 handoff의 "Standing constraints"에 R1~R3·D1·A1 **verbatim 보존** 확인 |
| 자동 이어가기 | `compaction.autoContinue` | `true` | handoff 후 새 세션 자동 생성(세션 파일 1→2) |
| cold resume 방지 | `compaction.idleEnabled` | `true` | 방치 세션을 재개 전 축소 |

`handoffPromptExtension`은 built-in 안전·연속성 지침을 **보완**하며 대체하지 않는다(스키마 명시). 값:

> Preserve verbatim, in a section titled "Standing constraints": every user instruction still in force (scope limits, forbidden actions, approval state), every decision already made and its reason, and every rejected approach. Never summarize these away, never soften them, and never mark them resolved unless the user explicitly released them. Also record: files changed, verification already run with its result, and the exact next step.

## 새 세션의 과거 맥락 이해 (tracking)

두 경로가 있고, 신뢰도가 다르다.

| 경로 | 설정 | 산출물 | 실측 상태 |
|---|---|---|---|
| **handoff 문서 (주 경로)** | `compaction.handoffSaveToDisk=true` | `<session>/0.handoff.log` + `artifact://` URI. "Standing constraints"에 규칙·결정·거부안·변경파일·검증·다음단계 포함 | **생성·보존 실측 완료** |
| local memory (보조) | `memory.backend=local`, `memories.enabled=true` | `memory_summary.md` + 다음 세션에 요약 주입 | thread(rollout) DB 등록은 확인. 최종 `memory_summary.md`는 **미실측** |

memory 파이프라인의 미실측 이유(정직 고지):

- Phase1 소비는 `memories.minRolloutIdleHours`(기본 **12시간**) 경과 + 이후 startup + 비동기 모델 호출로 완료된다.
- headless `gjc -p` 테스트 하네스는 그 비동기 통합이 끝나기 전에 프로세스가 종료된다(serena async-hook과 동일한 제약).
- idle을 0으로 낮춰도 short-lived `-p`에서는 `memory_summary.md` 생성을 재현하지 못했다. 대화형 세션에서 완료되는 구조로 보인다.
- 또한 idle을 상시 0으로 두면 매 세션마다 통합 모델 호출이 추가되어 "사용량 절감" 목적과 상충한다. 그래서 기본 idle을 유지한다.

결론: **새 세션 맥락 인계의 검증된 수단은 handoff 문서(디스크 저장 + artifact URI)** 다. local memory는 배경 보강으로 켜두되, 의존하지 않는다.

## 표준 task envelope

```text
목표: <이번 작업의 한 문장 목표>
범위: <허용된 파일 또는 모듈>
금지: <삭제/commit/push/네트워크 등 이번 작업에서 금지할 행위>
승인 상태: <조사만 | 구현 승인됨 | 검증만>
완료 조건: <관측 가능한 결과와 실행할 검증>
```

불변 규칙은 위 envelope에 반복하지 않는다. 변경이 필요한 경우에만 프로젝트 계약을 수정하고, 변경 사유를 남긴다.

## 표준 handoff

```text
결정: <확정된 설계·범위>
변경: <파일과 핵심 변경>
검증: <실행한 명령과 결과>
미해결: <다음 세션이 확인할 사실>
금지/제약: <계속 유효한 제약만>
```

handoff는 원문 대화, 대형 도구 출력, 로그 전문을 포함하지 않는다. 근거가 필요하면 파일 경로와 행 범위만 기록한다.

## 운영 중단 기준

다음 중 하나가 관측되면 해당 장기 세션을 계속 확장하지 않고 handoff 후 새 세션으로 전환한다.

- GJC에서 100K 이상 input과 `cacheRead=0`이 반복된다.
- OMO compaction이 실패하고 컨텍스트가 압축 전 수준으로 유지된다.
- 대형 도구 출력 또는 로그 전문이 대화에 누적됐다.
- 작업 목표가 바뀌어 기존 대화 대부분이 현재 작업에 불필요하다.

## 근거 경로

- `.gjc/_session-01a00ab0-6155-7000-9ce1-92ebac36a3fd/token-logs/token-log.jsonl`
- `.gjc/_session-01a0a26e-8db8-7211-bbdc-6b229e609760/token-logs/token-log.jsonl`
- `~/.omo/agent/sessions/--home-byun-PROject-boltz-v2-with-my-features-.claude-worktrees-boltz-red--/2026-09-15T00-55-12-837Z_01a0a28f-90c4-7c7e-be34-1644dec90e95.jsonl`
- `~/.omo/agent/logs/compaction.log`
