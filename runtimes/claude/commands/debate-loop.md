---
description: "3자 AI 토론 — Claude+Codex+Antigravity가 멀티턴으로 비판적 합의에 도달"
---

# 3자 AI 토론 (Debate Loop)

> **Migration note (2026-06-18)**: Gemini CLI 지원 종료에 따라 3rd 참여자가 Gemini → Antigravity (`agy`) 로 교체됨. MCP 호출도 `mcp__gemini-mcp__ask_gemini` → `mcp__antigravity-mcp__ask_antigravity` 로 변경.

사용자가 제시한 주제에 대해 Claude(오케스트레이터), Codex, Antigravity가 **비판적 토론**을 진행하여 합의에 도달하라.

## 핵심 원칙

1. **Claude = 오케스트레이터**: 이 skill 파일을 읽고, 프롬프트를 구성하여, 토론을 진행하고, 라운드마다 합의/분쟁을 정리
2. **Codex = 참여자 A**: Claude가 구성한 프롬프트만 받아 독립적 분석 제공
3. **Antigravity = 참여자 B**: Claude가 구성한 프롬프트만 받아 독립적 분석 제공
4. **비판적 합의**: 단순 동의가 아닌, 근거 기반 반박과 수렴
5. **멀티턴**: 각 참여자의 이전 발언을 다음 라운드에 포함. `session_id` 로 각 참여자 컨텍스트를 누적 유지

## 데이터 흐름

```
사용자 → /debate-loop {주제}
           ↓
Claude가 이 skill 파일을 읽음 (Claude만 읽음)
           ↓
Claude가 주제 기반 프롬프트를 구성
           ↓
   ┌───────┴───────┐
   ↓               ↓
Codex (MCP)    Antigravity (MCP)  ← 프롬프트 + working_directory로 프로젝트 파일 접근 가능
   ↓               ↓
   └───────┬───────┘
           ↓
Claude가 응답 수집 → 합의/분쟁 정리 → 다음 라운드 또는 종료
```

**참고:**
- Codex/Antigravity는 working_directory 기준으로 프로젝트 파일을 읽을 수 있음
- 주제에 코드/파일 분석이 필요하면 working_directory를 지정하여 맥락 제공
- 이전 라운드의 합의/분쟁은 구조화 템플릿으로 프롬프트에 포함하여 전달
- 양 MCP 모두 응답이 `{"session_id": "...", "response": "..."}` JSON. 첫 라운드에서 받은 `session_id` 를 다음 라운드 호출에 `session_id` 파라미터로 넘기면 각 참여자의 누적 컨텍스트가 보존됨 (codex / antigravity 둘 다 지원)

## 모델 설정

MCP 호출 시 `model` 파라미터로 최신 모델을 지정한다:

| 참여자 | 기본 모델 | 최신 모델 (권장) |
|---|---|---|
| Codex | o4-mini | gpt-5.4 |
| Antigravity | (CLI default, `--model` 미지원) | n/a — agy 는 모델 플래그 없음, 환경변수 `MCP_ANTIGRAVITY_DEFAULT_MODEL` 로만 라벨 부착 |

사용자가 `--latest` 플래그를 붙이면 codex 최신 모델 사용:
- `/debate-loop --latest VQ codebook 크기` → gpt-5.4 + agy default
- `/debate-loop VQ codebook 크기` → 기본 모델 (비용 절감)

## 토론 주제

```
$ARGUMENTS
```

## 실행 절차

### 라운드 1: 독립 분석

**Codex와 Antigravity에게 동시에 질문한다** (병렬 실행):

Codex 프롬프트:
```
다음 주제에 대해 분석하라. 근거를 반드시 제시하라.
주제: {$ARGUMENTS}

출력 형식:
## 주장
(핵심 주장 1-3개)
## 근거
(각 주장의 근거)
## 리스크/한계
(반대 의견이 있을 수 있는 부분)
```

Antigravity 프롬프트: (동일)

**MCP 호출 (병렬):**
- `mcp__codex-mcp__ask_codex` (background=false, model=선택된 모델)
- `mcp__antigravity-mcp__ask_antigravity` (background=false)

각 응답의 `response` 필드를 정리하고 `session_id` 를 보관 → 라운드 2 이상에서 같은 참여자를 호출할 때 재사용. 두 응답을 수집한 후, Claude가 **분쟁점(disagreements)**과 **합의점(agreements)**을 정리한다.

### 라운드 2~N: 교차 반박

**Codex와 Antigravity에게 교차 반박을 병렬로 동시 요청한다:**

Codex 프롬프트:
```
이전 라운드 상태:
## 합의 사항 (N개)
- {합의 내용}
## 분쟁 사항 (M개)
- 논점: {X} / Codex 입장: {Y} / Antigravity 입장: {Z}
## 이번 라운드 질문
Antigravity의 주장에 대해:
1. 동의하는 부분과 그 이유
2. 반박하는 부분과 근거
3. 수정된 최종 입장
```

Antigravity 프롬프트: (동일 구조, Codex의 의견을 전달)

**MCP 호출 (병렬):**
- `mcp__codex-mcp__ask_codex` (background=false, session_id=R1 codex session_id)
- `mcp__antigravity-mcp__ask_antigravity` (background=false, session_id=R1 antigravity session_id)

Claude가 두 반박을 수집한 후 **수렴 판정**을 수행한다.

### 수렴 판정

매 라운드 종료 시 Claude가 명시적으로 카운트한다:

```
라운드 N 판정: 합의 X개 / 분쟁 Y개 / 새로운 논점 Z개
```

다음 중 하나를 만족하면 토론 종료:
1. **분쟁 0개**: 모든 주요 논점에서 합의 → 합의 정리
2. **교착**: 분쟁 수와 내용이 이전 라운드와 동일 → 합의 정리 (미해결 분쟁 포함)
3. **최대 라운드 도달**: 4라운드 → 강제 합의 정리

### 합의 정리

Claude가 최종 정리:

```markdown
## 토론 결과: {주제}

### 합의 사항
- (3자 모두 동의한 내용)

### 조건부 합의
- (2자 동의, 1자 조건부 동의)

### 미해결 분쟁
- (합의 실패 항목 + 각자의 근거)

### 최종 권장사항
- (Claude의 종합 판단)

### 토론 라운드 요약
- R1: (독립 분석)
- R2: (교차 반박)
- R3: (수렴/교착)
```

## 멀티턴 세션 관리

- 각 라운드에서 Codex/Antigravity를 호출할 때 **이전 라운드의 상태를 구조화 템플릿으로 전달**
- 첫 라운드 응답에서 받은 `session_id` 를 다음 라운드 호출에 `session_id` 파라미터로 그대로 넘긴다 → 참여자 측에서도 자기 대화 컨텍스트를 누적 유지
- `background=false`로 호출하여 응답을 즉시 받음
- 상태 전달 템플릿 (2000자 이내):

```
## 합의 사항 (N개)
- {합의 내용}
## 분쟁 사항 (M개)
- 논점: {X} / Codex 입장: {Y} / Antigravity 입장: {Z}
## 이번 라운드 질문
- {구체적 반박 요청}
```

- 자유 서술이 아닌 이 템플릿을 사용하여 정보 손실과 토큰 낭비를 방지

## /loop 모드

사용자가 `/loop`과 함께 사용하면:
- 토론 종료 후 "추가 논의할 주제가 있는가?" 확인
- 있으면 새 토론 시작
- 없으면 종료

## 에러 처리

- **Timeout**: 60초 내 응답 없으면 해당 참여자 skip, 사용자에게 "[X] 응답 timeout — 2자 토론으로 진행" 알림. Antigravity는 인증/세션 부팅으로 첫 호출이 다소 느릴 수 있어 첫 라운드는 120초까지 허용 권장
- **에러**: 1회 재시도 후 실패 시 skip
- **비정상 응답**: 응답이 무의미한 반복이거나 주제와 무관하면 해당 참여자 skip. Antigravity `-p` 재개 모드는 직전 턴의 답을 echo 하는 quirk 가 있으므로, 새 라운드 응답에서 이전 발언 그대로가 prefix 로 붙어있다면 그 부분은 무시하고 신규 응답만 발췌
- **2자 격하**: 한쪽만 응답 시 Claude가 부재 참여자의 역할을 대신하지 않음. 응답한 참여자의 분석만으로 진행
- **양쪽 실패**: 토론 중단, 사용자에게 "Codex/Antigravity 모두 응답 불가 — MCP 연결 확인 필요" 알림

## 주의사항

- Claude는 중립 오케스트레이터이지 토론 참여자가 아님. 단, 최종 권장사항에서는 Claude의 판단을 포함
- 상태 전달은 반드시 구조화 템플릿을 사용 (자유 서술 금지)
- Codex/Antigravity에게 로컬 파일 읽기를 요청하지 않는다. 필요한 맥락은 프롬프트에 텍스트로 포함
