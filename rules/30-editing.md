# 편집·구현 규칙 (30-editing)

## 편집 규칙

- 기존 프로젝트 스타일과 로컬 helper API를 우선한다.
- 설치, 설정, migration, hook, config 로직은 idempotent하게 만든다.
- 구조화 파일은 구조를 존중해서 편집한다: JSON은 parse/merge, YAML/TOML은 필요한 key만 수정, Markdown은 관련 섹션 갱신, ignore 파일은 누락 라인만 추가.
- 주석은 비자명한 의사결정이나 제약을 설명할 때만 추가한다.
- 필요성이 명확하지 않은 새 의존성은 추가하지 않는다.

## 명령 및 도구 사용

- 검색은 `rg`, 파일 목록은 `rg --files`를 우선한다.
- 토큰 사용량이 큰 명령(`git status`/`git log`/`ls -R`/대용량 파일 dump 등)은 `rtk` 또는 `context-mode` sandbox 실행으로 raw output을 컨텍스트 밖에 둔다. 분석은 결과 요약·검색으로 접근한다.
- 전역/user config를 바꾸는 명령은 임시 디렉터리나 격리된 환경변수로 먼저 검증한다.
- 프로젝트 밖에 쓰기, 패키지 설치, 네트워크 호출, 실제 홈 설정 변경은 민감한 작업으로 취급한다.
- `rm`, `git reset`, checkout/revert 같은 destructive command는 명시 요청이나 승인 없이 실행하지 않는다.
- sandbox/network 제한으로 실패하면 우회하지 말고 실패 이유와 필요한 승인을 설명한다.
