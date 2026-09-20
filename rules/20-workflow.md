# 작업 절차 (20-workflow)

workflow·skill·persistent mode는 typed-human이 명시적으로 이름을 들었거나 accepted
task contract가 요구할 때만 활성화한다. 일반어 keyword는 실행 권한이 아니다.

## Spec Gate — 코드보다 명세 먼저

- 새 프로젝트·기능은 목표, 범위, non-goal, 성공 기준, 검증 방법을 먼저 확정한다.
- 모호한 요청은 필요한 범위만 질문한다. 명시된 직접 구현은 별도 workflow로 감싸지 않는다.
- 자동 workflow는 reviewed scope envelope와 proposal digest가 없으면 구현 단계에 진입하지 않는다.

## 의사결정 지원

- 선택지는 근거, 비용, 위험, 되돌릴 수 있는지, 검증 비용으로 비교한다.
- 결정을 뒤집을 수 있는 가장 작은 확인을 먼저 실행한다.
- 정보가 부족하면 진행을 막는 선택만 질문한다.

## 코드 변경 전 분석

- entry point와 producer → input → processing → output → consumer를 확인한다.
- 구조·타입·현재 동작을 관찰한 뒤 원인을 작은 독립 가설로 나눠 검증한다.
- 세 단계 이상은 ToDo로 추적하고 완료 즉시 갱신한다. task 수 자체를 진척으로 보지 않는다.
