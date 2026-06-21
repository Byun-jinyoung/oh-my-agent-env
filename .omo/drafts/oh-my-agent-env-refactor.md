---
slug: oh-my-agent-env-refactor
status: awaiting-approval
intent: clear
pending-action: write .omo/plans/oh-my-agent-env-refactor.md
approach: Behavior-preserving refactor plan only. First lock current setup/sync/doctor responsibilities and invariants, then split monolithic shell phases by domain while preserving Bash, command names, idempotent semantics, and cross-machine runtime parity.
---

# Draft: oh-my-agent-env-refactor

## Components (topology ledger)
<!-- Lock the SHAPE before depth. One row per top-level component that can succeed or fail independently. -->
<!-- id | outcome (one line) | status: active|deferred | evidence path -->
| id | outcome | status | evidence path |
| --- | --- | --- | --- |
| C1 | Bootstrap CLI keeps thin dispatch for `sync`, `doctor`, `validate`, `update`, `install`, `init-project`. | active | `setup.sh:1-13`, `setup.sh:53-64`, `setup.sh:237-242` |
| C2 | Sync orchestration remains ordered and idempotent, but large phases are split by domain. | active | `lib/sync.sh:1-8`, `lib/sync.sh:1056-1121` |
| C3 | Config editors and reusable helpers become testable units without changing global config behavior. | active | `lib/common.sh:72-132`, `lib/common.sh:336-657` |
| C4 | Doctor verification becomes domain-grouped checks with machine-readable enough output for parity drift. | active | `lib/doctor.sh:5-217` |
| C5 | Runtime parity sources of truth stay explicit: rules, skills registry, MCP/plugin setup, CLI runtimes. | active | `skills/registry.yaml:1-58`, `rules/`, `runtimes/` |
| C6 | Repo hygiene and architecture tooling must not mislead refactor decisions. | active | `.gitignore:1-23`, `graphify-out/GRAPH_REPORT.md` |

## Open assumptions (announced defaults)
<!-- Record any default you adopt instead of asking, so the user can veto it at the gate. -->
<!-- assumption | adopted default | rationale | reversible? -->
| assumption | adopted default | rationale | reversible? |
| --- | --- | --- | --- |
| Implementation language | Keep Bash for setup/sync/doctor; do not wholesale migrate to Python/Node. | Current package is shell-first and cross-machine bootstrap should minimize runtime prerequisites. | Yes |
| Current LazyCodex changes | Treat existing uncommitted LazyCodex integration as protected baseline, not part of this planning task. | User asked to investigate/refactor-plan package structure, and product code must not be modified now. | Yes |
| Refactor style | Extract and regroup behavior first; defer semantic improvements. | Reduces risk to reproducibility/idempotency/runtime parity. | Yes |
| Test timing | Plan tests-after/smoke verification rather than strict TDD. | Current shell code has no visible test harness; extraction should first create stable seams and then verify commands. | Yes |
| Architecture graph | Fix or account for graphify vendor pollution before using graph metrics as authoritative. | `GRAPH_REPORT.md` is dominated by minified Mermaid symbols from a vendored file. | Yes |

## Findings (cited - path:lines)
- Purpose is cross-machine environment reproduction: `README.md:1-3` says one-command setup for multiple machines; quick start is `git clone`, `cd`, `./setup.sh sync`, `./setup.sh doctor` at `README.md:25-33`.
- CLI entrypoint is already relatively thin: `setup.sh:1-13` documents commands; `setup.sh:53-64` sources `lib/common.sh`, `lib/sync.sh`, `lib/doctor.sh`; `setup.sh:237-242` dispatches by command.
- `setup.sh` still owns nontrivial workflows: `cmd_validate` at `setup.sh:66-80`, legacy `cmd_install` at `setup.sh:91-110`, and project initialization at `setup.sh:113-235`.
- `lib/sync.sh` explicitly says the old monolithic `cmd_sync` was decomposed into ordered phase functions and relies on Bash dynamic scope: `lib/sync.sh:1-8`.
- The main complexity has moved from `setup.sh` into sync phases: `sync_external_tools` spans tool install/update behavior at `lib/sync.sh:128-313`; `sync_plugins_mcp` handles plugin/MCP registration and migration at `lib/sync.sh:315-625`; `sync_agent_mcp_frameworks` handles Codex/Antigravity MCP config and frameworks at `lib/sync.sh:627-1054`.
- `cmd_sync` is an orchestration layer with skip-network handling and phase order at `lib/sync.sh:1056-1121`; this is the right boundary to preserve while extracting internals.
- `lib/common.sh` mixes low-level helpers and high-level config writers: npm prefix/security at `lib/common.sh:72-132`, Codex context-mode/global config writing around `lib/common.sh:336-471`, global rule assembly at `lib/common.sh:641-657`, and hook enforcement at `lib/common.sh:666-722`.
- `lib/doctor.sh` is a single report/check function starting at `lib/doctor.sh:5`; it checks npm prefix, secrets, CLI tools, symlinks, plugins, MCPs, context-mode, LazyCodex, and related runtime state in one long path.
- `skills/registry.yaml:1-58` is a real source of truth for skill parity by agent/runtime and external MCP dependencies.
- `.gitignore:1-23` already separates machine-local state such as `node_modules/`, `.env`, `.serena/`, `.code-review-graph/`, `graphify-out/`, `.codex-gemini-mcp/`, and `local/`; this supports reproducibility if setup regenerates these instead of committing them.
- Existing `IMPROVEMENT_PLAN.md` already identified a prior direction: lean top-level setup, modular rules, and three-CLI parity. Current code partially achieved that; remaining refactor pressure is concentrated in `lib/sync.sh`, `lib/common.sh`, and `lib/doctor.sh`.
- `graphify-out/GRAPH_REPORT.md` exists, but its god nodes are minified/vendor-like symbols from `skills/codebase-scan/vendor/mermaid.min.js`; architecture conclusions from that graph need filtering or `.graphifyignore` adjustment first.
- Codegraph could not be used for this package because the project is not initialized for it. Observed error: `CodeGraph not initialized in /Users/byunjin-young/.oh-my-agent-env. Run 'codegraph init' in that project first.`

## Decisions (with rationale)
- Plan should prioritize an inventory and invariant document before edits. Reason: reproducibility/idempotency/runtime parity are behavioral guarantees, not just file layout goals.
- Keep `cmd_sync` as the public orchestrator and split internal domains below it. Reason: command UX and phase order are user-facing compatibility.
- Split `sync_external_tools`, `sync_plugins_mcp`, and `sync_agent_mcp_frameworks` first. Reason: they are the largest mixed-responsibility regions and carry the most runtime parity risk.
- Split doctor into reusable domain checks after sync boundaries are named. Reason: doctor should verify the same domains that sync mutates.
- Preserve the current machine-local exclusions and regenerate local state. Reason: `.gitignore` already encodes the custom package boundary between portable config and host-local artifacts.

## Scope IN
- 조사 결과 기반 리팩터 계획 작성.
- setup/sync/doctor 책임 분리 기준 정의.
- 재현성, idempotency, runtime parity 기준과 검증 전략 정의.
- 기존 LazyCodex 설치 구성은 현재 baseline으로 반영하되 이번 요청에서 수정하지 않음.
- `.omo/drafts/`와 `.omo/plans/` 산출물 작성.

## Scope OUT (Must NOT have)
- 제품 코드 수정 금지: `setup.sh`, `lib/*.sh`, `README.md`, `rules/`, `skills/`, runtime 파일 변경 금지.
- 실제 리팩터 구현 금지.
- 패키지 설치, 플러그인 재설치, 전역 설정 변경 금지.
- 기존 사용자 변경사항 되돌리기 금지.
- Bash에서 다른 언어로의 대규모 재작성 계획 금지.

## Open questions
1. 현재 uncommitted LazyCodex 변경을 refactor baseline으로 포함할까요? 추천: 포함. 이미 사용자 요청으로 설치 구성된 상태이므로, 계획은 이를 보호 대상으로 다루는 편이 안전합니다.
2. 분리 단위는 `lib/sync/*.sh`, `lib/doctor/*.sh`, `lib/config/*.sh` 같은 domain split으로 잡을까요? 추천: 예. 함수 단위 산개보다 setup/sync/doctor parity 검증과 대응됩니다.
3. 테스트 전략은 tests-after smoke/harness 방식으로 둘까요? 추천: 예. 현재 shell 테스트 프레임워크가 없으므로, 먼저 behavior-preserving extraction 계획과 `bash -n`, dry-run, isolated HOME smoke를 묶는 편이 현실적입니다.

## Approval gate
status: awaiting-approval
Pending user approval before writing `.omo/plans/oh-my-agent-env-refactor.md`.
<!-- When exploration is exhausted and unknowns are answered, set status: awaiting-approval. -->
<!-- That durable record is the loop guard: on a later turn read it and resume at the gate instead of re-running exploration. -->
