# herdr: sub-agent·peer를 띄울 때

사용자가 원하는 상태는 아래 세 가지이며, 셋 다 지켜야 한다.
1. **트리**: peer의 `parent`가 main이다.
2. **탭**: peer마다 자기 탭이 따로 있다. main 탭에 split으로 넣지 않는다.
3. **중복 없음**: 사이드바에는 peer가 부모 밑 트리로만 나온다. 이것은 Mac 앱의 `my-layout`이 처리한다.

상세 근거와 이력은 `~/.claude/rules/herdr-agent-tree.md`에 있다. 이 파일과 충돌하면 그 문서가 우선이다.

## 띄우기 (모든 머신 공통)
```sh
hc run --bg --name <이름> -- <명령>     # main 터미널 안에서 실행하면 parent가 자동으로 main이 된다
```
- `--name`은 `a-z 0-9 - _` 조합으로 1-32자이며, 실행 중인 터미널끼리 겹치면 안 된다. main 밖에서 띄우면 `--parent <main 주소>`를 붙이고, `--no-parent`는 쓰지 않는다.
- **금지 1:** `--keep`, `--label herdr.space=…`, `--label herdr.tab=…`. tab id를 지어내도 탭이 생기지 않고 main 탭에 split으로 몰린다(2026-11-11 lcdd-master에서 10개 실측).
- **금지 2:** 옛 `herdr` CLI(legacy server). 그 pane은 herdr-app에 보이지 않는다.
- **사용자가 herdr-app 새 탭으로 띄운 peer**는 hc에서 `parent`가 null이고 바꿀 수 없다. main은 그 peer마다 `hc label <주소> herdr.parent=$HC_TERMINAL_ID`를 붙인다. Mac의 `my-agents`가 이 라벨을 부모로 써서 트리를 그린다. 이 라벨은 사이드바 표시용일 뿐이며, `hc wait --children`과 부모 종료 시 함께 종료되는 동작에는 반영되지 않는다.

## 탭 만들기
- 탭은 Mac의 herdr-app 명령으로만 생긴다. 원격 머신(lcdd-local, lcdd-server, lcdd-cluster, lcdd-ai-master)에는 `herdr-app`이 없고, `hc`에는 탭 명령이 없다. `hc keep`도 탭을 만드는 명령이 아니다.
- **원격 main**은 띄우기까지만 하고 사용자에게 이렇게 알린다: "Mac에서 `herdr-keep-missing --apply`를 실행하면 탭이 생깁니다." 앱 구조를 조사하거나 다른 우회책을 시도하지 않는다.
- **Mac main**(`command -v herdr-app`이 있는 경우)은 `herdr-keep-missing`(dry-run)으로 할 일을 확인한 뒤 `herdr-keep-missing --apply`를 직접 실행한다.
- **oms-panel**(이름이 `oms-panel`로 시작)은 자기 탭이 아니라 main과 같은 탭에서 main의 왼쪽 분할로 둔다. 같은 명령이 이것도 처리하므로 따로 할 일은 없다.
- 이미 main 탭에 몰린 pane도 같은 명령이 각자의 탭으로 옮긴다. 옮기지 않을 터미널은 `--skip <name>`으로 제외한다.

## 보고
- `hc ls --json`으로 각 peer의 `name`·주소·`parent`(= main 주소)를 확인해 보고한다.
- 원격에서는 탭과 사이드바를 볼 수 없다. 따라서 "탭을 확인했다"고 쓰지 않고, 탭은 사용자 확인 항목으로 남긴다.
