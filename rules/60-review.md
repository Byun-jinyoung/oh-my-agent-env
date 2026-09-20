# 검토·리뷰 가이드라인 (60-review)

## 리뷰 규칙

- 리뷰에서는 findings를 먼저, 심각도순으로 제시한다.
- 가능한 경우 정확한 파일과 라인을 인용한다.
- 확인된 문제, 위험, 열린 질문을 구분한다.
- correctness, maintainability, user-facing quality에 영향 없는 style-only comment는 피한다.
- 문제가 없으면 남은 검증 공백만 설명한다.

## Subagent 규칙

- 독립적인 다중 파일 구현·조사·review는 좁은 파일 범위로 위임한다.
- agent 간 작업과 gate 실행을 중복시키지 않고, parent가 최종 diff와 검증을 소유한다.
- peer 합의는 evidence이지 승인이나 scope 확장이 아니다.
