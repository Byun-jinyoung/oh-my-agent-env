# 검토·리뷰 가이드라인 (60-review)

## 리뷰 규칙

- 리뷰에서는 findings를 먼저, 심각도순으로 제시한다.
- 가능한 경우 정확한 파일과 라인을 인용한다.
- 확인된 문제, 위험, 열린 질문을 구분한다.
- correctness, maintainability, user-facing quality에 영향 없는 style-only comment는 피한다.
- 문제가 없으면 문제가 없다고 말하고, 남아 있는 검증 공백을 설명한다.

## Subagent 규칙

- 사용자가 subagent, parallel agent, expert review를 명시했고 도구 지침이 허용할 때만 사용한다.
- 각 subagent에는 좁고 구체적인 작업을 준다.
- agent 간 작업을 중복시키지 않는다.
- subagent 결과는 요약하고, 불일치나 미해결점을 표시한다.
- 사용자가 codex cross-review를 지시하면, 원본 사용자 지시 사항을 그대로 주입해 codex와 multi-turn 대화로 cross-review를 진행하고, 합의/이견/미해결점을 요약해 보고한다.
