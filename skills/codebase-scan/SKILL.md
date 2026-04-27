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
| `standard` (기본) | ~5분 | 0, 1, 2, 3, 5 |
| `deep` | ~20분+ | 0, 1, 2, 3, 4, 5 |

모드 미지정 시: 파일 수 < 20 → quick, ≤ 500 → standard, > 500 → standard (deep은 명시 요청 필요)

## 사전 조건

필수 설치 (한 번만):
```bash
pip3 install --user code-review-graph   # L1 — 반드시 필요
```

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
