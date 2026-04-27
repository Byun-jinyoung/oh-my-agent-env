---
name: triangle-review
description: 3-way parallel code review by Claude + Codex + Gemini, each using its own MCP/skills independently. Produces JSON findings per peer, mechanically clusters by (file, line±3, category), applies hybrid severity consensus (3/3 CONSENSUS, 2/3 MAJORITY, 1/3 SINGLE, critical-in-set promotes + DEBATE flag), writes unified CODE-REVIEW.md. Trigger on "triangle review", "트라이앵글 리뷰", "3자 리뷰", "peer review this PR", "3-way code review", "Claude Codex Gemini 같이 리뷰".
---

# triangle-review — 3-way AI peer review with mechanical consensus

## 목적

한 리뷰 대상(diff 또는 repo)에 대해 Claude/Codex/Gemini가 **각자 자기 MCP/skills로 독립 조사** → 공통 JSON 스키마로 finding 제출 → cluster 병합 + 하이브리드 severity 합의 → `CODE-REVIEW.md` 하나로 통합.

설계 근거: `PROject/AI_Tools/Claude/triangle-review-design.md` (Section 1~3).

## 사전 조건

- `code-review-graph` pip 설치됨 (Claude, Codex, Gemini 모두에서)
- Codex/Gemini에 `serena`, `code-review-graph` MCP 등록됨 (`codex mcp list`, `gemini mcp list`로 확인)
- `~/.claude/skills/codebase-scan/` symlink로 3 runtime이 공유 중
- `mcp__codex-mcp__ask_codex`, `mcp__gemini-mcp__ask_gemini` 사용 가능

## 실행 플로우

### Phase 0 — 타깃 정규화

사용자 입력 예:
- `triangle-review .` → repo 전체
- `triangle-review HEAD~1..HEAD` → diff
- `triangle-review path/to/file.py` → 단일 파일

반드시:
```bash
cd <repo_root>
git rev-parse --show-toplevel
```

`.claude/triangle-review/<run_id>/` 디렉토리 생성 (run_id = `date +%Y%m%dT%H%M%S`).

### Phase 1 — 공유 evidence baseline

**한 번만** codebase-scan 실행하여 `.claude/codebase-scan/evidence/L1-facts.md` + `L1-evidence.json` 생성. 이미 있으면 mtime < 1h일 때만 재사용.

```bash
python3 ~/.claude/skills/codebase-scan/scripts/audit_claims.py --emit-evidence <repo_root>
```

이 baseline은 3자 peer가 **모두 같은 fact를 보고** 리뷰하도록 보장 (false disagreement 차단).

### Phase 2 — 병렬 spawn (3자 동시 호출)

세 호출을 **단일 assistant 턴에서 병렬**로 보낸다 (독립적이므로).

#### Peer 프롬프트 템플릿 (Codex/Gemini 공통)

```
ROLE: You are a peer code reviewer in a 3-way Triangle Review.
TARGET: <diff spec or repo path>
EVIDENCE BASELINE (MUST read first): <repo>/.claude/codebase-scan/evidence/L1-facts.md

TOOLS AVAILABLE TO YOU:
- serena MCP (symbol lookup, reference search)
- code-review-graph MCP (CALLS/INHERITS edges, blast radius)
- codebase-scan skill (if deeper analysis needed)

DELIVERABLE: Output ONLY a single JSON object. No markdown fence. No prose before/after.

SCHEMA:
{
  "reviewer": "codex" | "gemini",
  "repo": "<absolute path>",
  "run_id": "<echo back exactly>",
  "findings": [
    {
      "id": "F-<reviewer>-001",
      "file": "<repo-relative path>",
      "line_start": <int>,
      "line_end": <int>,
      "category": "bug" | "smell" | "security" | "perf" | "style" | "architecture",
      "severity": "critical" | "major" | "minor" | "info",
      "summary": "<=120 chars",
      "detail": "free text",
      "evidence_ids": ["BLAST-01", "HUB-02"],
      "suggestion": "optional"
    }
  ]
}

RULES:
- Every "architecture" finding MUST cite at least one evidence_id from L1-evidence.json.
- line_start/line_end are integers pointing to the target revision (post-diff if reviewing a diff).
- Do not fabricate evidence IDs. If unsure, use evidence_ids: [].
- run_id: <PASS THROUGH EXACT STRING>
- **Quote rule (CRITICAL for line anchoring)**: `detail` MUST contain at least one
  exact code snippet copied verbatim from the target file, wrapped in single
  backticks (e.g. `` `os.system(f"curl -L {url}")` ``). The orchestrator's
  anchor_lines pass uses these snippets to grep the actual file and auto-correct
  line_start/line_end if your reported lines drift. Findings without a quoted
  snippet keep your raw line numbers (no correction possible).
- Snippet must be ≥6 chars and not a single bare identifier (e.g. `cfg` is too
  generic; `cfg.paths.output_dir` is fine).
```

#### Codex 호출

```
mcp__codex-mcp__ask_codex(
  prompt=<template with TARGET=... and run_id=...>,
  cwd=<repo_root>,
  reasoning_effort="medium",  # minimal은 web_search와 충돌
  async_exec=true
)
```

#### Gemini 호출 (직접 spawn — wrapper 우회)

**중요**: `mcp__gemini-mcp__ask_gemini` wrapper는 사용 금지. E2E 검증(2026-04-24)으로 입증: wrapper가 `gemini --prompt ... --model ...`만 spawn하고 `--yolo` / `--allowed-mcp-server-names`를 주지 않아, non-interactive 모드의 approval 게이트가 external MCP tool을 LLM의 tool_declarations에서 배제함 (`serena_failed:tool_not_found_in_tool_declarations`). Gemini는 `default_api:*` 내장 tool만 사용 가능하여 hallucinated finding을 산출함.

대신 helper script로 직접 spawn:

```bash
# 프롬프트를 파일로 저장 (Bash heredoc 인용 이슈 회피)
PROMPT_FILE=.claude/triangle-review/<run_id>/gemini_prompt.txt
cat > "$PROMPT_FILE" <<'EOF'
<peer 프롬프트 템플릿 (TARGET, run_id 치환 완료)>
EOF

# Claude는 이 한 줄을 background로 돌린다 (Bash run_in_background=true)
bash ~/.claude/skills/triangle-review/scripts/call_gemini.sh \
  "$PROMPT_FILE" \
  "<repo_root>" \
  ".claude/triangle-review/<run_id>/gemini.json"
```

Helper가 자동 처리:
- `gemini --yolo --allowed-mcp-server-names serena --allowed-mcp-server-names code-review-graph -p "$(cat prompt.txt)"`
- stdout을 `gemini.json.raw`로 보존
- 가장 큰 balanced `{...}` JSON 블록 추출 → `gemini.json` 기록

새 MCP를 Gemini에 공유하게 되면 `call_gemini.sh`의 `--allowed-mcp-server-names` 리스트 확장 필요.

#### Claude 자체 수행

같은 프롬프트 계약에 따라 serena + CRG로 직접 조사 후 JSON 생성. 저장 경로: `.claude/triangle-review/<run_id>/claude.json`.

### Phase 3 — 결과 수합

`mcp__codex-mcp__wait_for_job`, `mcp__gemini-mcp__wait_for_job`으로 병렬 wait.

각 응답에서 JSON 블록 추출 → `.claude/triangle-review/<run_id>/{codex,gemini}.json` 저장.

실패/타임아웃 처리:
- 한 peer 타임아웃 → 나머지 2자로 MAJORITY/SINGLE 계속 진행
- JSON 파싱 실패 → 1회 "JSON만 다시 출력해줘" 재호출, 2회째 실패 시 해당 peer 탈락

### Phase 3.5 — Line anchoring (자동, diff_findings에 통합)

`diff_findings.py --repo <repo>`가 cluster 직전에 `anchor_lines.py`를 호출하여 각 finding의 `line_start`/`line_end`를 실제 파일에서 인용된 code snippet의 grep 위치로 자동 보정. Phase 4 파일럿 측정: line 정확도 15% → 95% (+80pp).

각 finding에 `line_anchor_status`가 부착됨:
- `verified` / `verified_within_tolerance_N`: peer line이 정확하거나 ±3 이내
- `envelope_verified`: peer 범위가 anchor 위치를 포함 (함수 단위 인용 등)
- `corrected_drift_N`: peer line이 N라인 drift → anchor 위치로 재작성
- `no_anchor` / `no_quoted_snippet`: 인용 부족 → peer 원본 유지

**핵심 효과**: line drift가 큰 peer의 finding이 정확한 위치로 보정되어 cluster 병합률이 올라감 (Phase 4 검증: CONSENSUS 0 → 1).

요건: peer detail에 **백틱으로 감싼 정확한 code 인용**이 있어야 anchor 가능. 이는 peer 프롬프트의 "exact code quote" 규칙으로 강제됨.

### Phase 4 — 기계적 합의

```bash
python3 ~/.claude/skills/triangle-review/scripts/diff_findings.py \
  --run-dir .claude/triangle-review/<run_id> \
  --out .claude/triangle-review/<run_id>/CODE-REVIEW.md \
  --repo <repo_root>     # ← 권장 (anchor_lines 자동 적용)
```

`--repo` 생략 시 anchoring 건너뜀(legacy 동작). `--no-anchor`로 명시적 비활성화 가능.

스크립트 동작:
1. `claude.json`, `codex.json`, `gemini.json` 로드 (없는 파일은 skip + 로그)
2. **(--repo 시)** 각 finding에 `anchor_lines.anchor_finding` 적용 → line 보정 + JSON 다시 저장
3. 모든 finding을 cluster 키 `(file, line-overlap±tol, category)`로 병합
4. 같은 cluster 내:
   - reviewers 수 → confidence (3=HIGH, 2=MEDIUM, 1=LOW)
   - severity 집합 → Q-A (c) 하이브리드:
     - unique(S)==1 → severity=S[0], DEBATE=False
     - "critical" ∈ S → severity="critical", DEBATE=True
     - 그 외 → severity=max(S), DEBATE=True
5. 섹션 순서: Summary → CONSENSUS(HIGH) → MAJORITY(MEDIUM) → SINGLE(LOW) → DEBATE
6. 각 cluster는 3 reviewer의 원 rationale/detail을 보존

### Phase 4.5 — Debate (선택, `--debate=disagreement|both`)

DEBATE flag cluster (또는 `--debate=both` 시 CONSENSUS도)를 selectively multi-turn으로 재검증. 각 peer는 자신의 Round 1 verdict를 `agree`/`revise`/`withdraw`로 갱신.

```bash
# 1. 타깃 추리고 batched 프롬프트 생성
python3 ~/.claude/skills/triangle-review/scripts/debate_round2.py prepare \
  --run-dir <run_dir> --repo <repo_root> --mode disagreement
# 산출: <run_dir>/debate/{targets,clusters_pre}.json + round2_prompt.txt

# 2. orchestrator가 3 peer 병렬 spawn (Phase 2와 동일 메커니즘):
#    - codex: mcp__codex-mcp__ask_codex 로 prompt 전달, response를 codex_round2.json 으로 저장
#    - gemini: call_gemini.sh 로 prompt 전달 → gemini_round2.json
#    - claude: 본인이 직접 serena.read_file 재확인 후 claude_round2.json 작성

# 3. verdict들을 cluster에 적용 후 보고서 재생성
python3 ~/.claude/skills/triangle-review/scripts/debate_round2.py merge --run-dir <run_dir>
# 산출: <run_dir>/CODE-REVIEW.md (Round 2 annotated) + debate/clusters_post.json
```

**모드**:
- `--debate=disagreement` (기본 활성화 시) — DEBATE flag만 재검증. 비용 ↓, ROI ↑
- `--debate=both` — CONSENSUS도 재검증 (paranoid 모드, false-positive 0% 노림)
- 미지정 — Round 2 skip (가장 저렴)

**Round 2 결과 status**:
| status | 의미 |
|---|---|
| `DEBATE_RESOLVED` | Round 1 disagreement → Round 2 합의 도달 |
| `DEBATE_PERSISTED` | 재검증 후에도 disagreement 지속 (인간 검토 필수) |
| `CONSENSUS_CONFIRMED` | `--debate=both`로 CONSENSUS 재확인됨 |
| `DISMISSED` | 모든 peer가 withdraw — false alarm |
| `REVISED` | severity 변경됨 (단방향 합의) |
| `NOT_DEBATED` | Round 2 대상 아니었음 (대부분 cluster) |

**검증된 동작 (Phase 4 ml-simplefold)**: 2 DEBATE cluster 재검증 → gemini가 critical로 상향, claude가 minor로 하향. 양방향 이동 모두 발생 → multi-turn이 실제로 verdict를 바꿈을 입증.

### Phase 5 — 최종 보고

`.claude/triangle-review/<run_id>/CODE-REVIEW.md` 경로를 사용자에게 알림.

요약 한 줄: "Triangle review complete: N CONSENSUS, M MAJORITY, K SINGLE, D DEBATE_PERSISTED, X DISMISSED. See <path>."

## 실패 복구

| 실패 | 대응 |
|---|---|
| codebase-scan L1-facts.md 생성 실패 | Phase 1 없이 진행 (evidence_ids=[] 허용), 라벨 "NO_BASELINE" |
| peer JSON 파싱 실패 2회 | 해당 peer 탈락, 남은 2자로 진행 |
| 3 peer 모두 실패 | Triangle review 중단, `.claude/triangle-review/<run_id>/FAILED.md` 기록 |
| Codex wait_for_job 타임아웃 (기본 10분) | 완료된 peer로만 진행 |
| `call_gemini.sh` "no valid JSON object" (exit 3) | `.raw` 파일을 로그로 보존 + 1회 재시도 (프롬프트에 "JSON만 출력" 강조) → 실패 시 Gemini 탈락 |
| Gemini가 `default_api:*`만 사용 (MCP 누락) | `call_gemini.sh`의 `--allowed-mcp-server-names` 플래그 누락 회귀. `gemini mcp list`로 서버 Connected 확인 후 스크립트 수정 |
| anchor `no_anchor` 비율이 높음 | peer가 detail에 백틱 인용을 안 남긴 경우. peer 프롬프트의 "Quote rule"이 무시된 것이므로 1회 재호출 권고. 그래도 안되면 peer 원본 line 유지 (보정 불가, 부정확할 수 있음 경고) |
| `--repo` 미지정으로 anchor 단계 skip | `diff_findings.py`에 `--repo <repo_root>` 추가. line drift가 큰 finding(특히 Gemini)이 cluster 병합에 실패할 수 있음 |

## 모드

| 모드 | 동작 |
|---|---|
| `--fast` | Gemini 생략, Claude + Codex 2-way (MAJORITY/SINGLE만) |
| `--diff-only` | `git diff` 출력만 분석 대상 (repo 전체 스캔 생략) |
| `--debate=disagreement` | Round 2 selective multi-turn — DEBATE flag cluster만 재검증 |
| `--debate=both` | Round 2 — DEBATE + CONSENSUS 모두 재검증 (paranoid, FP 0% 노림) |
| 기본 | 3-way full, Round 1만 (debate 비활성) |

## 비용 안내

- 3 peer 각자 LLM 호출 → 토큰 비용 Claude-only의 ~3배
- 사전 `L1-facts.md` 공유로 중복 조사 최소화
- 대형 repo(>5000 파일)는 `--diff-only` 강력 권장

## 참고

- `diff_findings.py`: `~/.claude/skills/triangle-review/scripts/diff_findings.py`
- 설계 문서: `PROject/AI_Tools/Claude/triangle-review-design.md`
- 공유 baseline: `codebase-scan` skill의 L1 산출물
