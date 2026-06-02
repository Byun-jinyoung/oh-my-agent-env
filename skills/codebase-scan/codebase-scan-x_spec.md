# codebase-scan-x — 확장 spec (2026-05-20)

## 목표
LLM이 매 세션 codebase 재분석에 토큰을 낭비하는 문제를 해결한다. repo/codebase를 사전에 다층 분석 → 영구 문서화 → 이후 세션이 참조 가능한 형태로 저장한다.

## Base
`~/.cc-bootstrap/skills/codebase-scan/` (기존 user skill)을 in-place 확장한다. 동일 명 유지(`codebase-scan`).

## Gap → 추가 Phase

| Gap | 해결 | 신규 Phase |
|---|---|---|
| HTML 출력 부재 | `graphify update <repo>`가 graph.html을 자동 생성 → Phase 6에서 link | **Phase 6a** |
| Obsidian 미통합 | `Research/{proj}/codemap/`에 wikilink 발행 | **Phase 6b** |
| 데이터 I/O/타입 흐름 분석 부재 | Python `ast` + `typing`/`pydantic`/`dataclass` 추출 | **Phase 2.5** |
| Multi-tool 합의 부재 | graphify hubs ↔ CRG hubs ↔ understand-anything domain-graph ↔ codex-mcp 검토 | **Phase 4.5** |

## 새 산출물 구조
```
<repo>/.codemap/                          # raw artifact (gitignore 권장)
  evidence/L1.json, L1-facts.md, L2.json, L1-evidence.json
  dataflow/functions.json                 # Phase 2.5 신규
  consensus/hubs-consensus.md             # Phase 4.5 신규
  consensus/disagreements.md
  graphify-out/                           # graphify update 산출물 (graph.json/.html/GRAPH_REPORT.md)
  CODEBASE-MAP.md                         # 통합 markdown (기존)

<vault>/Research/{proj}/codemap/          # Obsidian용 (Phase 6b)
  index.md                                # entry, wikilink 허브
  architecture.md                         # Phase 5 narrative 발췌
  dataflow.md                             # Phase 2.5 함수별 I/O/타입 표
  facts.md                                # L1-facts.md 복사
  consensus.md                            # Phase 4.5 결과
  html-report.md                          # graphify HTML로 가는 링크 임베드
```

## Phase 2.5 — Data Flow & Types (신규)
**입력**: L1.json의 blast 상위 N개 파일(기본 15) + 모든 entry point(`__main__`, CLI typer/click, `if __name__`)
**처리**: Python `ast`로 함수/메서드 추출 → signature, return annotation, docstring 1줄, 주요 호출(call graph 1-hop), 데이터 구조(dataclass/pydantic/TypedDict/NamedTuple 정의 detection)
**출력**: `dataflow/functions.json` (스키마: `{file, name, params:[{name,type}], returns, calls:[fqn], data_classes:[{name, fields:[{name,type}]}]}`) + `dataflow/dataflow.md` 표

**ML 프로젝트 보강**: torch `nn.Module.forward` signature를 별도 추출, tensor shape annotation 주석 패턴 (`# (B, N, D)`) 정규식 캡처.

## Phase 4.5 — Multi-tool Consensus (신규)
1. **graphify 실행**: `graphify update <repo>` → hubs/communities JSON 추출 (graph.json/.html/GRAPH_REPORT.md 한 번에 생성)
2. **understand-anything 실행** (있으면): domain-graph.json 활용
3. **mcp-code-graph / CodeGraph MCP** (등록 시): hub/centrality 쿼리
4. **codex-mcp 2-round**: round1 = Claude의 hub 초안 + 근거를 codex에 제시 → round2 = codex 반론/보완 요청. 응답을 JSON으로 파싱.
5. **Consensus 알고리즘** (triangle-review 스타일):
   - 동일 hub 파일이 ≥3개 도구에서 top-10에 등장 → **CONSENSUS**
   - 2/N → **MAJORITY**
   - 1/N → **SINGLE**
   - top-1 자리에 다른 파일이 오면 → **DEBATE** 플래그
6. **산출**: `consensus/hubs-consensus.md` (consensus 표 + DEBATE 항목 explanation)

## Phase 6 — Publishing (신규)
**6a — HTML**: Phase 4.5에서 `graphify update <repo>`로 이미 생성된 `<repo>/graphify-out/{graph.json, graph.html, GRAPH_REPORT.md}`를 그대로 사용. `CODEBASE-MAP.md`/`html-report.md`에 상대경로 링크 삽입 (별도 빌드 단계 불필요).

**6b — Obsidian**: vault `Research/{proj}/codemap/` 생성 (CLAUDE.md 규칙 — Research/는 활성 작업 디렉토리이므로 이 경우는 사용자 명시 결정으로 예외). frontmatter `tags: [codemap, {proj}]` + wikilink로 architecture/dataflow/facts/consensus 상호 연결. HTML 리포트는 `![[graphify-out/index.html]]` 임베드.

## Cross-review (skill 외부)
Skill 실행 후 별도로:
- `multi-agent-review` skill 호출 — 산출물을 subagent들이 검토
- codex-mcp multi-turn — Phase 4.5에서 이미 사용, 여기선 추가 "이 분석에 빠진 측면" 질문

## 성공 기준
1. if-dfm pilot 실행 후 `.codemap/` + `Research/if-dfm/codemap/` 양쪽 생성됨
2. 다음 세션에서 LLM이 `Research/if-dfm/codemap/index.md`만 읽고 if-dfm 구조를 token-efficient하게 파악 가능
3. dataflow.md에 핵심 함수 ≥20개의 I/O type이 명시됨
4. consensus.md에 ≥3개 도구의 hub 의견이 비교됨
5. multi-agent-review subagent들이 산출물에 PASS

## 검증 방법
- Skill 실행 → 산출물 생성 확인
- 신규 세션에서 `index.md`만 읽고 사용자 질문 ("이 repo 구조 설명") 답변 가능한지 사용자 확인
- audit_claims.py `--check` 통과
