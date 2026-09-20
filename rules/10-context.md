# 컨텍스트 관리 (10-context)

## 컨텍스트 명확화

- 프로젝트 맥락이 필요한 요청이면 계획 전 관련 파일을 읽는다.
- 로컬 파일, 명령 출력, 제공 문서로 확인할 수 있는 내용은 묻지 않는다.
- 충돌하거나 결과를 바꾸는 모호성이 남으면 짧은 질문 하나로 확정한다.
- 맥락이 불완전하면 **아는 것 / 모르는 것 / 검증이 필요한 것 / 배제할 것** 네 축으로 분리해 정리한다.

## 코드 그래프 우선 (graft / graphify)

- 코드 read·조사·검색·수정·설계 시 **원시 `grep`/`rg`/전체 파일 `read`보다 코드 그래프 도구를 먼저** 쓴다. 토큰이 대략 1/10이고 탐색 왕복을 없앤다.
- 정의·구조·호출관계·영향범위 질의는 `graft ask`/`graft grep`/`graft skeleton`/`graft callers`(`-d N` 전이 영향)/`graft map`을 우선한다. graft는 매 질의 전 워킹트리 대비 그래프를 재빌드하므로($0·키 불필요·~3ms) 커밋 안 한 편집도 항상 반영된다.
- 교차모듈 아키텍처·경로·설명 질의는 `graphify query`/`graphify path`/`graphify explain`도 병행한다(scope가 `graphify-out/` 읽기를 허용할 때).
- graft 사용은 전역 훅(Claude `~/.claude/settings.json`·Codex `~/.codex/hooks.json`·GJC graft-nudge)이 유도한다. 별도 MCP 서버는 없으니 위 `graft` CLI를 직접 쓴다.
- 원시 텍스트 검색은 그래프가 못 잡는 비코드 파일·문자열 리터럴 전수조사 등 그래프가 부적합할 때로 한정한다.

## 컨텍스트 연속성

- 재개할 때는 최신 사용자 목표, 완료된 증거, 현재 tree, 남은 제한을 다시 확인한다.
- 오래된 summary·hook state·agent message보다 현재 파일과 typed-human 지시를 우선한다.
- 방향이 바뀌면 바꾼 근거를 남기고, 같은 조사를 반복하지 않는다.
