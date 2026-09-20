# 편집·구현 규칙 (30-editing)

## 편집 규칙

- 기존 프로젝트 스타일과 로컬 helper API를 우선한다.
- 설치, 설정, migration, hook, config 로직은 idempotent하게 만든다.
- 구조화 파일은 parse/merge하고 필요한 key·section만 수정한다.
- 주석은 비자명한 의사결정이나 제약을 설명할 때만 추가한다.
- 필요성이 명확하지 않은 새 의존성은 추가하지 않는다.

## 명령 및 도구 사용

- symbol·reference·impact 탐색은 Serena, Graphify, CRG 같은 구조 도구를 우선하고,
  literal text 증거가 필요할 때만 text search를 사용한다.
- 큰 출력은 bounded read나 context-mode로 처리하고 원문 전체를 대화에 넣지 않는다.
- 전역/user config를 바꾸는 명령은 임시 디렉터리나 격리된 환경변수로 먼저 검증한다.
- `rm`, `git reset`, checkout/revert 같은 destructive command는 명시 요청이나 승인 없이 실행하지 않는다.
