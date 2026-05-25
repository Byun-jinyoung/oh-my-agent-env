---
name: codebase-scan
description: Orchestrated codebase comprehension for unfamiliar projects. Runs code-review-graph (CRG) for relational structure, serena/tree-sitter for symbols, optionally gsd:map-codebase for prose synthesis, then mechanically audits prose claims against CRG quantitative facts via stable evidence IDs. Trigger on "이 repo 파악해줘", "새 프로젝트 온보딩", "codebase map", "understand this codebase", "analyze this repository structure", "이 프로젝트 구조 알려줘", "onboard to this project", "map this repo".
---

# codebase-scan — 다층 코드베이스 파악 스킬

## 목적

낯선 repo에 투입될 때 세 가지 독립 데이터원(관계/심볼/프로즈)을 수집하고, **프로즈 주장을 수치 증거로 감사**하여 신뢰할 수 있는 코드베이스 지도를 만든다.

## 도구 역할 분담 (설계 근거: pilot 검증됨)

| 도구 | 생산 데이터 | 고유 여부 |
|---|---|---|
| `code-review-graph` (CRG) | edges (CALLS/INHERITS/IMPORTS), blast radius, hubs | **유일** |
| `serena` MCP | LSP 기반 심볼/레퍼런스 (Python 등) | 대체 불가 (언어 지원) |
| tree-sitter / ast | 언어 무관 구문 심볼 폴백 | serena 없을 때만 |
| `gsd:map-codebase` | 4-focus 프로즈 (tech/arch/quality/concerns) | 감사 대상 |

**주의 — pilot이 밝힌 것**:
- serena vs tree-sitter top-level 심볼은 **100% 중복**. 둘 다 돌리지 않는다. 언어로 분기하여 하나만.
- 교차검증은 *"세 도구 합의"*가 아니라 **"프로즈 주장 ↔ CRG 수치"** 축에서만 신호를 낸다.

## 실행 모드

| 모드 | 소요 | 실행 Phase |
|---|---|---|
| `quick` | ~1분 | 0, 1 |
| `standard` (기본) | ~5분 | 0, 1, 2, 2.5, 3, 5, 6 |
| `deep` | ~20분+ | 0, 1, 2, 2.5, 3, 4, 4.5, 5, 6 |

모드 미지정 시: 파일 수 < 20 → quick, ≤ 500 → standard, > 500 → standard (deep은 명시 요청 필요)

**신규 Phase (2.5 / 4.5 / 6)**:
- **2.5** — Data flow & types: 함수 signature, return type, dataclass/pydantic/TypedDict/torch nn.Module 필드, tensor shape 주석 캡처
- **4.5** — Multi-tool hub consensus: graphify + CRG + codex-mcp(+antigravity-mcp) 합의 (CONSENSUS/MAJORITY/SINGLE/DEBATE)
- **6** — Publishing: graphify HTML + Obsidian `Research/{proj}/codemap/` wikilink 발행

## 사전 조건

필수 설치 (한 번만):
```bash
# 권장: 시스템 Python 버전과 무관하게 isolated env로 설치
uv tool install code-review-graph        # L1 — 반드시 필요

# 대체: 시스템 Python ≥ 3.10 환경에서만 동작
pip3 install --user code-review-graph
```

> CRG는 Python ≥ 3.10을 요구한다. 시스템 Python이 3.8/3.9이면 `pip3` 경로는
> "No matching distribution"으로 실패하므로 `uv tool install`을 사용한다.
> `setup.sh sync`는 [10] 단계에서 자동 설치를 시도한다.

serena는 user scope에 이미 등록되어 있어야 함 (없으면 Phase 2에서 tree-sitter 폴백).

## Phase 0 — 감지 (항상 실행)

```bash
cd <target_repo>
git rev-parse --show-toplevel  # repo root 확인
FILES=$(git ls-files 2>/dev/null | wc -l)
LANGS=$(git ls-files | awk -F. '{print $NF}' | sort | uniq -c | sort -rn | head -5)
```

- `FILES`, `LANGS` 기록
- 주 언어 결정 → Phase 2 경로 결정 (Python이면 serena, 기타면 tree-sitter)
- `.claude/codebase-scan/state.json` 생성하여 모드/경로/언어 저장

## Phase 1 — L1 인덱싱 (모든 모드)

```bash
code-review-graph build --repo .
python3 ~/.claude/skills/codebase-scan/scripts/extract_l1.py <repo_root>
```

산출물: `.claude/codebase-scan/evidence/L1.json` (nodes, edges, hubs, blast, inheritance).

실패 시: CRG 미설치 → `pip3 install --user code-review-graph` 안내 후 **중단** (L1 없으면 Phase 3 audit 불가능). build 에러는 `.claude/codebase-scan/logs/crg.log`에 보존 후 중단.

## Phase 2 — L2 심볼 맵 (standard/deep)

언어 분기:

**Python 우세** → serena 사용:
1. `mcp__serena__activate_project <repo_root>` 호출
2. 핵심 파일 선정: L1.json의 blast-radius 상위 10개 파일
3. 각 파일에 `mcp__serena__get_symbols_overview` 호출
4. 결과를 `.claude/codebase-scan/evidence/L2.json`에 집계

**기타 언어** → tree-sitter 폴백:
- `tree-sitter parse <file>` 사용, Python `ast` 대체
- 주요 파일(상위 10개)만 파싱

**전체 파일 스캔 지양**: pilot에서 top-level 심볼 100% 동일 확인됨. 샘플링으로 충분.

## Phase 2.5 — Data Flow & Types (standard/deep, Python 한정)

```bash
python3 ~/.claude/skills/codebase-scan/scripts/extract_dataflow.py <repo_root> --top 15
```

산출물: `.claude/codebase-scan/dataflow/{functions.json, dataflow.md}`

추출 내용:
- 함수/메서드 signature: 각 파라미터의 `name: type`, return annotation
- 데이터 구조: `@dataclass` / `pydantic.BaseModel` / `TypedDict` / `NamedTuple` 정의의 필드 + 타입
- ML 보강: `torch.nn.Module.forward`는 `kind=forward`로 별도 표시. 본문의 `# (B, N, D)` 형식 shape 주석을 docstring에 첨부
- 호출 그래프 1-hop: 각 함수가 호출하는 함수명 최대 12개

선정 기준: L1.json blast 상위 N개 파일 → 없으면 `src/**/*.py` 전체 fallback.

비-Python 프로젝트: 이 Phase를 스킵하고 `functions.json = {}`로 빈 파일 작성.

## Phase 3 — Evidence IDs + audit baseline (standard/deep)

```bash
python3 ~/.claude/skills/codebase-scan/scripts/audit_claims.py --emit-evidence <repo_root>
```

산출물 (항상 둘 다 생성):
- `.claude/codebase-scan/evidence/L1-facts.md` — 사람이 읽는 표 (BLAST / HUB / INHERIT / COMM)
- `.claude/codebase-scan/evidence/L1-evidence.json` — **stable IDs**: `BLAST-01..10`, `HUB-01..15`, `INHERIT-01..10`, `COMM-01..05`

**Phase 4가 이 ID를 인용**해야 Phase 4의 프로즈가 audit을 통과한다.

## Phase 4 — 프로즈 합성 + 강제 post-check (deep only)

규모 게이트: 파일 < 20 → 스킵.

**Step 4a** `/gsd:map-codebase`를 호출할 때 프롬프트에 다음 제약을 **그대로** 포함한다:

```
Context files (MUST read):
  .claude/codebase-scan/evidence/L1.json
  .claude/codebase-scan/evidence/L1-facts.md
  .claude/codebase-scan/evidence/L1-evidence.json
  .claude/codebase-scan/evidence/L2.json

Citation contract:
  모든 architectural claim 문장은 반드시 `[EVIDENCE: <ID>[, <ID>]]` 태그로 끝나야 한다.
  Claim-type → evidence-type 매핑 (audit가 강제):
  - "core | central | main entry | critical path" → BLAST-*
  - "hub | heavily used | frequently called"     → HUB-*
  - "inherits | extends | framework base"         → INHERIT-*
  - "community | cluster | flow | subsystem"      → COMM-*

Example:
  `simplefold.py는 이 repo의 중앙 실행 모듈이다 [EVIDENCE: BLAST-01].`

Forbidden: 태그 없는 architectural claim, L1-evidence.json에 없는 ID, claim과 evidence type 불일치.
```

**Step 4b** gsd 출력물(`.planning/codebase/*.md` 또는 지정 경로)에 대해 즉시 audit:

```bash
python3 ~/.claude/skills/codebase-scan/scripts/audit_claims.py --check <repo_root> <gsd_output_md>
```

`--check` 검증 규칙:
1. 모든 `[EVIDENCE: ...]` ID가 `L1-evidence.json`에 존재
2. 키워드(core/central/hub/inherits/community/...) 포함 문장은 citation 보유
3. claim-type과 cited evidence-type이 매칭 (예: `core` → BLAST만 허용)
4. 실패 시 exit 1 + `.claude/codebase-scan/evidence/audit-report.md` 작성

**Step 4c** (bounded retry): audit 실패 시 audit-report.md를 gsd 프롬프트에 append해서 **1회만** 재호출. 두 번째도 실패하면 해당 프로즈를 Phase 5의 Narrative에서 제외하고 `UNVERIFIED (audit failed)` 섹션으로 격리.

## Phase 4.5 — Multi-tool Hub Consensus (deep)

여러 분석 도구의 hub/centrality 의견을 모아 합의 라벨을 부여한다.

### Step 4.5a — graphify 실행
```bash
graphify <repo_root> --no-viz
```
산출: `<repo_root>/graphify-out/graph.json`

### Step 4.5b — codex-mcp 2-round 질의 (Claude가 직접 수행)

세션 안에서 `mcp__codex-mcp__ask_codex` 호출:

**Round 1** (초안 요청):
```
프롬프트: "이 repo의 top-5 hub 파일을 JSON으로 답하라.
스키마: {\"hubs\":[{\"file\":\"<rel/path.py>\",\"rank\":<int>,\"why\":\"<짧은 근거>\"}]}.
근거는 import/호출 빈도, 코드량, 데이터 흐름의 중심성 기준."
```

**Round 2** (반론/보완):
Round 1 응답 + CRG L1-facts.md + graphify hubs를 함께 제시하며:
```
"이 hub 후보들을 본 후, 당신의 초안을 수정할 부분이 있는가?
누락된 hub나, 잘못 포함된 항목이 있다면 동일 JSON 스키마로 갱신본을 내라."
```

Round 2 응답을 `.claude/codebase-scan/consensus/codex.json`에 저장.

(선택) antigravity-mcp도 동일 프로토콜로 호출 → `antigravity.json` 저장.

### Step 4.5c — Consensus 계산
```bash
python3 ~/.claude/skills/codebase-scan/scripts/consensus_hubs.py \
  --crg <repo_root>/.claude/codebase-scan/evidence/L1.json \
  --graphify <repo_root>/graphify-out/graph.json \
  --codex <repo_root>/.claude/codebase-scan/consensus/codex.json \
  --top-k 10 \
  --out <repo_root>/.claude/codebase-scan/consensus
```

산출: `consensus/{hubs-consensus.md, hubs-consensus.json, disagreements.md}`

라벨 규칙: top-10 중 ≥3 sources = **CONSENSUS** / 2 = **MAJORITY** / 1 = **SINGLE**. rank-1 후보가 도구별로 다르면 **DEBATE** 플래그.

실패 시: ≥2 sources 미달이면 Phase 4.5 스킵 + 로그에 사유 기록.

## Phase 5 — 통합 산출물

`.claude/codebase-scan/CODEBASE-MAP.md` 작성. confidence 라벨 규칙 **결정 테이블**:

| 섹션 | 출처 | confidence |
|---|---|---|
| Scope | Phase 0 state.json | HIGH (결정적) |
| Architecture Facts | L1-evidence.json → 표 직접 인용 | HIGH (결정적) |
| Symbol Index | L2.json (Phase 2) | HIGH (LSP/tree-sitter 추출) |
| Narrative (Audited) | Phase 4 프로즈 중 `--check` PASS한 문장만 | AUDITED |
| UNVERIFIED | Phase 4 실패 문장 또는 Phase 4 미실행 | UNVERIFIED |
| Open Questions | L1/L2가 못 잡은 영역 (동적 dispatch, reflection 등) — LLM이 열거 | OPEN |

각 섹션 헤더에 confidence 라벨을 표기. Narrative 문장은 원본 `[EVIDENCE: ...]` 태그를 유지해야 함.

사용자가 `/init` 또는 `/tutor-setup`을 원하면 이 파일을 입력으로 제공.

## Phase 6 — Publishing (standard/deep)

### Step 6a — HTML 인터랙티브 리포트

Phase 4.5에서 `graphify --no-viz`로 graph.json만 뽑았다면, HTML이 필요할 때 추가로:
```bash
graphify <repo_root>            # default가 HTML 포함이라 재실행 가능. --update로 증분.
```
산출: `<repo_root>/graphify-out/index.html` + JSON + GRAPH_REPORT.md.

### Step 6b — Obsidian vault 발행

```bash
python3 ~/.claude/skills/codebase-scan/scripts/publish_obsidian.py <repo_root> \
  --vault ~/PROject/vault \
  --proj <project_slug> \
  --subdir Research
```

산출: `<vault>/Research/<proj>/codemap/`
- `index.md` — entry-point, wikilink 허브 (frontmatter `tags: [codemap, <proj>]`)
- `architecture.md` — Phase 5 `CODEBASE-MAP.md` 복사
- `dataflow.md` — Phase 2.5 dataflow 표
- `facts.md` — Phase 3 L1-facts
- `consensus.md` — Phase 4.5 합의 표 (있으면)
- `html-report.md` — graphify HTML 경로 안내

**다음 세션에서 LLM 사용법**: 새 세션 시작 시 `Research/<proj>/codemap/index.md`를 먼저 읽음 → 작업 관련 wikilink만 따라가서 토큰 절약. 코드 재스캔 불필요.

**주의 — vault 정책**: 이 repo CLAUDE.md는 보통 `Research/` 수정을 금지하나, codemap 출력은 사용자 명시 예외로 허용된다. 다른 파일은 건드리지 말 것.

## 상호보완 ↔ 교차검증 요약

- **상호보완**: L1(관계) + L2(심볼) = 합집합으로 coverage 최대화
- **교차검증**: L3 프로즈의 모든 architectural claim → `--check`가 기계적으로 ID/type 검증 → UNVERIFIED 격리
- **배제**: serena-vs-tree-sitter diff는 pilot에서 신호 없음 확인 → 실행 안 함

## 실패 복구

| 실패 | 대응 |
|---|---|
| CRG 미설치 | pip 안내, skill **중단** (L1 없이는 audit 불가능) |
| CRG build 실패 | 로그 `.claude/codebase-scan/logs/crg.log` 보존 후 **중단** (부분 그래프 기반 audit은 신뢰도 붕괴) |
| `git` 저장소 아님 / `git ls-files` 비어있음 | Phase 0에서 `find . -type f -name '*.py'` 등으로 대체 스캔, `.gitignore` 없음을 로그에 명시 |
| serena activate 실패 | tree-sitter 폴백 (동일한 blast 상위 10 파일 파싱) |
| tree-sitter parser 미설치 (해당 언어) | `pip install tree-sitter-language-pack`로 기본 제공. 그래도 실패하면 Phase 2 스킵하고 L2.json = `{}`로 생성 (Symbol Index는 빈 섹션) |
| gsd:map-codebase 미설치 / Phase 4 audit 2회 실패 | Phase 4 산출물을 Narrative에서 제외하고 `UNVERIFIED` 섹션으로 격리. Phase 5는 L1+L2만으로 생성 |
| 파일 > 5000 | 사용자에게 deep 모드 확인 후 진행. vendor/generated 디렉토리 (`node_modules/`, `dist/`, `__pycache__/`, `.venv/`)는 CRG가 기본 제외 |
| `.claude/` 쓰기 실패 (read-only FS) | 사용자에게 대체 경로 요청 (`CODEBASE_SCAN_DIR` 환경변수), 기본은 `$(pwd)/.claude/codebase-scan/` |
