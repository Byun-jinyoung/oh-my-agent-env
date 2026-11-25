# herdr: main 아래 peer는 트리 + 탭, 사이드바는 중복 없이 트리로

적용: herdr(`hc` / `herdr-app`)에서 main 세션이 sub-agent·peer를 띄우거나 정리할 때, 그리고 사이드바·레이아웃·머신 설정을 만질 때.
근거: `~/.config/herdr-app/AGENTS.md:136-160`, `herdr.d.ts:59-75`, 2026-11-06 실측(19개 터미널 대조 전부 통과).

## 사용자 목표 (세 조건 모두 동시에)
1. **트리**: peer는 main의 자식(`parent` = main 주소)으로 사이드바 트리에 묶인다.
2. **탭 유지**: 각 peer는 자기 pane(= 탭)을 가진다.
3. **사이드바 중복 없음**: 탭이 있는 peer도 사이드바에서는 **부모 밑 트리에만** 보이고, 최상위 행으로 다시 나오지 않는다.

탭을 없애서 중복을 없애는 것(`park`)도, 탭만 만들고 중복을 방치하는 것도 이 목표를 어긴다. 해석이 갈리면 위 세 줄로 돌아온다.

## 원리
- 트리는 `parent`, 탭은 pane으로 정해지며 둘은 독립이다. `hc run`으로 시작하면 parent가 자동 기록되고, sub-agent는 pane 없이 시작한다(`AGENTS.md:157-160`).
- `terminal.keep`은 pane을 만들고, `terminal.park`은 pane을 없앤다(`herdr.d.ts:62-63`).
- 원본 `agents` mod는 pane이 있는 sub-agent를 최상위에도 그린다. 이 중복이 조건 3을 깨므로 복제 mod `my-agents`와 그것을 쓰는 레이아웃 `my-layout`을 쓴다.

## 1회 설정 (완료 상태: 2026-11-06)
| 파일 | 내용 |
|---|---|
| `~/.config/herdr-app/mods/my-agents/main.js` | `mods/agents` 복제(`mod.clone`). 수정: `:170-173` 클릭 시 pane이 있으면 `pane.focus`, 없으면 `terminal.peek` / `:176-183` `parentOf()`·`tree()`가 대리 부모 사용 / `:239-258` main 재시작 시 대리 부모 계산(아래 절) / `:268-275` 부모(또는 대리 부모)가 live agent이면 최상위에서 제외, 대리 부모로 대체된 옛 main 행도 제외 / `:279-280` `setAgentOrder`를 부모 → 자식 순서로 |
| `~/.config/herdr-app/layouts/my-layout.json` | `main` 복제. `agents` 블록의 mod만 `my-agents`로 교체 |

원본 `mods/agents`, `layouts/main.json`은 수정하지 않는다. 출고본은 시작할 때 교체된다(`herdr.d.ts:75`).

적용과 확인:
```sh
herdr-app do layout.switch '{"name":"my-layout"}'
herdr-app do layout.show '{"id":"sidebar"}'     # my-layout에 숨김 상태가 저장돼 있으면 사이드바가 안 보이므로 함께 실행
herdr-app status                                 # layout=my-layout, errors 확인
```
- 숨김 상태는 `layouts/.state/my-layout.json`의 `nodes.sidebar.hidden`에 저장된다. 이 파일은 손으로 고치지 말고 `layout.show`/`layout.hide`로 바꾼다.
- 사이드바를 껐다 켤 때는 `cmd-b`(`layout.toggle:sidebar`)를 쓴다. **`cmd-shift-l`(`layout.switch`, 다음 레이아웃)로 켜면 `main`으로 돌아가 중복이 다시 생긴다.** (실제로 이 경로로 두 번 되돌아갔다.)
- 사용자가 "사이드바 끄지 말라"고 했다. 레이아웃 전환이 필요하면 1회만 하고 곧바로 `layout.show sidebar`를 붙인다.
- 되돌리기: `herdr-app do layout.switch '{"name":"main"}'`.

## 새 peer 띄우기
```sh
hc run --bg --name <이름> -- <명령>            # main 터미널에서. parent 자동 = main
herdr-app do terminal.keep --terminal <주소>   # 탭 생성. 주소는 hc ls --json에서 name으로 조회
```
- `--name`: `a-z 0-9 - _`, 1-32자, live 터미널 중 유일. `--bg` 없으면 종료까지 대기.
- main 밖에서 띄우면 `--parent <main 주소>`를 붙인다. `--no-parent`는 쓰지 않는다.

## 탭이 생기는 위치
`keep`은 **현재 활성 space**에 탭을 붙인다(실측: 부모가 `IF-DLM`인데 활성 space `boltz-…`에 생김). 부모 space에 붙이려면:
```sh
herdr-app do space.select '{"id":"<부모 space id>"}'   # JSON 형식만 동작. --id 플래그는 엉뚱한 space(vault)로 감
# herdr-app ls 에서 그 space가 active로 바뀐 것을 확인한 뒤
herdr-app do terminal.keep --terminal <주소>
herdr-app do space.select '{"id":"<원래 space id>"}'
```
- space id는 `herdr-app ls`의 `spaces[].id`다(원격은 `<machine>/` 접두사 포함).
- 원격에서 연속으로 keep하면 두 번째부터 `A terminal's pane must stay on its own machine`로 거부된 적이 있다. 터미널마다 space를 다시 선택하고 확인한 뒤 실행한다.
- **라벨 방식은 탭을 만들지 못한다(2026-11-11 실측, lcdd-master RX_sequence-design).** `hc run --keep --label herdr.tab=<새로 지어낸 tb id>`로 띄운 sub-agent 10개는 라벨에 `where: …/3·4·5`가 찍혔지만, 그 tab id는 앱에 생기지 않았고 pane은 전부 main 탭(`1`)에 split으로 몰렸다. `herdr.tab=<main 탭 id>`로 띄워도 main 탭에 몰린다. 탭은 앱 명령(`terminal.keep`, `tab.new`)으로만 생긴다.
- 이미 main 탭에 pane으로 몰린 sub-agent를 자기 탭으로 옮기는 단일 명령은 없다(`tab.move`는 탭 순서만 바꿈, `herdr.d.ts:56`). `terminal.park` 직후 같은 space를 선택하고 `terminal.keep`하면 새 탭으로 다시 붙는다(park를 남겨 두는 것이 아니라 이동 용도). 2026-11-11 Mac 로컬 실측: main 탭에 split으로 넣은 시험 터미널이 이 순서로 자기 탭(탭 이름 = `--name`)으로 옮겨졌고, `live`·`parent`가 유지됐으며 `herdr.tab` 라벨은 새 탭 id로 바뀌었다. 원격도 같은 날 `herdr-keep-missing --apply --only worker_luna`로 확인했다: `lcdd-master/t20`이 main 탭에서 자기 탭 `worker_luna`로 옮겨졌고 `live`(codex)·`parent=t1k`가 유지됐다.

## 일괄 정리 도구: `herdr-keep-missing` (Mac `~/.local/bin`)
위 절차 전체를 기계적으로 수행한다. 수작업보다 이 도구를 먼저 쓴다.
```sh
herdr-keep-missing                     # dry-run: 할 일만 출력
herdr-keep-missing --apply             # 실행 후 전체 재검증, 남은 문제가 있으면 exit 1
herdr-keep-missing --apply --skip oms-panel --only worker_luna   # 주소나 name으로 제외·한정 (반복 가능)
```
- 레이아웃이 `my-layout`이 아니면 1회 전환하고 곧바로 `layout.show sidebar`를 실행한다.
- pane 없는 sub-agent → `KEEP`(부모 space 선택 → keep).
- 부모나 형제와 같은 탭에 있거나 다른 space에 있는 sub-agent → `MOVE`(park → 부모 space 선택 → keep). keep에 실패하면 `IT IS PARKED`를 출력하므로 손으로 keep한다.
- **oms-panel은 예외다(2026-11-12 사용자 지시).** 이름이 `oms-panel`로 시작하거나 agent가 `oms`인 sub-agent는 자기 탭을 만들지 않고 **부모(main)와 같은 탭에서 좌우 분할로 부모의 왼쪽**에 둔다 → `PANEL`. 순서: (pane이 있으면 park) → 부모 space 선택 → `pane.focus`(부모 pane) → `terminal.keep {terminal, place:"right"}` → `pane.swap {pane:<패널>, target:<부모 pane>}`. 이미 부모 탭에 있으면 건드리지 않는다(좌우 위치는 API로 읽을 수 없어 재실행 시 뒤집히지 않게 하려는 것). Mac에서 시험 터미널로 `herdr-app shot` 캡처를 보고 좌측 배치를 확인했고, lcdd-master `t22`에도 적용했다(`live`·`parent=t1k` 유지).
- 대상은 `parent`가 있는 live 터미널이다. 부모에 pane이 없으면 space를 알 수 없어 SKIP한다. 끝나면 원래 활성 space로 되돌린다.

## 이미 떠 있는 peer 정리
- `parent`가 있으면 `herdr-keep-missing`을 실행한다(수작업이라면 위 "탭이 생기는 위치" 절차로 `keep`). `park`했던 것도 `keep`으로 복구된다.
- `parent`가 없는 세션을 나중에 main 밑으로 옮기는 명령은 없다(`hc run --help`에도 re-parent가 없다). herdr-app의 `tab.new`와 `terminal.open`에도 parent 인자가 없어서, 사용자가 herdr-app 새 탭으로 띄운 peer는 항상 `parent: null`이다(2026-11-15 lcdd-master `t5m` 등 10개 실측).
  - 사이드바 트리만 필요하면 `hc label <peer> herdr.parent=<main 주소>`를 붙인다. `my-agents`의 `parentOf()`가 core `parent`가 없을 때 이 라벨을 쓴다.
  - 원격 라벨 값은 접두사 없이 쓴다(`t54`). mod가 peer 주소의 `machine/` 접두사를 붙여 비교한다(2026-11-15 수정).
  - 이 라벨은 표시용이다. `hc wait --children`, 부모 종료 시 자식 종료, `herdr-app ls`의 `sub_agents`에는 반영되지 않는다.

## 원격 머신에서 읽을 때 (lcdd-local / lcdd-server / lcdd-cluster / lcdd-ai-master)
- 원격 네 머신에는 `herdr-app`이 없고 `hc`만 있다(2026-11-10 실측, `lcdd-server`는 2026-11-11 실측: `command -v herdr-app` 비어 있음, `~/.config/herdr-app` 없음). 이 문서의 `herdr-app do …`, `mods/`, `layouts/` 경로는 **Mac**에 있다.
- mod·layout은 사이드바를 그리는 Mac 앱 쪽 설정이라 원격에 복사할 필요가 없다. 원격에서 띄운 세션도 Mac 사이드바에서 같은 규칙으로 그려진다.
- 원격 main이 할 일: `hc run --bg --name <이름> -- <명령>`까지(트리 = 조건 1). `--keep`·`--label herdr.*`는 붙이지 않는다(붙이면 main 탭에 pane으로 몰림). 탭(조건 2)은 Mac에서 `herdr-keep-missing --apply`로 만든다. 원격 main은 띄운 뒤 사용자에게 이 한 줄을 알리고, 앱 구조 조사나 우회 시도를 하지 않는다.
- **omo(pi) main은 이 파일을 읽지 않는다.** senpi rules 확장은 `~/.claude/rules/*.md` 중 frontmatter에 `alwaysApply: true`나 `globs`가 있는 것만 주입한다(`senpi/dist/core/extensions/builtin/rules/rules/matcher.js:6-16`, Mac omo 5.1.48 기준). omo가 매 세션 읽는 전역 파일은 agentDir의 `~/.omo/agent/AGENTS.md`다(`senpi/dist/core/context-files.js:147-156`). 그래서 이 문서의 원격 main 몫을 요약해 그 파일에 넣었다(2026-11-11, 5대).
- 원격 main은 옛 `herdr` CLI(legacy server)를 쓰지 않는다. 그 pane은 herdr-app에 보이지 않는다(2026-11-11 lcdd-master에서 실제로 9개가 보이지 않는 곳에 생겼다).
- `hc keep <t>`는 `herdr-app do terminal.keep`과 다르다. `hc --help` 설명은 "replace lost programs with a shell"이고, 탭을 만드는지는 시험하지 않았다 `[미확인]`. 탭 생성 대용으로 쓰지 않는다.
- 이전 판 문서의 "main 탭 라벨로 띄우고 별도 탭은 만들지 않는다"(`hc run --label herdr.tab=<main 탭>`)는 조건 2를 어기므로 폐기했다.

## omo를 agent로 표시하기 (2026-11-11)
- herdr는 OSC 7501로 상태를 보고하는 터미널만 agent로 그린다(`AGENTS.md:153`). omo는 pi 기반이며, `~/.omo/agent/extensions/herdr-omp-agent-state.ts`가 `app=pi`로 보고한다(herdr-core는 `HC_TERMINAL_ID`·`HC_TERMINAL_SOCKET`이 있을 때만).
- 원본: `~/.oh-my-env/runtimes/omo/extensions/herdr-omp-agent-state.ts`(배포 함수 `lib/sync/agent-clis.sh` `sync_omo_herdr_extension`). 이 문서 자체도 `~/.oh-my-env/runtimes/claude/rules/`에서 sync로 링크된다. `coreEnabled`가 없는 옛 판은 herdr-core에서 표시되지 않는다(lcdd-cluster 10-08 판이 그랬음).
- 2026-11-11 Mac·lcdd-local·lcdd-cluster·lcdd-server·lcdd-ai-master 모두 sha `efc95858…`로 맞췄다. 옛 판 백업은 `~/.omo/agent/extensions-backup/`. 실행 중인 omo는 `/reload` 또는 재시작해야 반영된다.
- omo 5.1.66(engine senpi 2026.11.9-2)은 내장 herdr 확장도 OSC 7501을 보낸다. 5.1.48은 보내지 않으므로 위 확장이 필요하다.
- 새 머신: 위 파일을 같은 경로에 복사하고 `hc run --on <머신> --bg --no-parent --name omo-probe -- bash -lic 'exec omo'`로 `agent=pi`를 확인한 뒤 `hc kill`·`hc rm`한다.

## main을 재시작했을 때 (2026-11-09, IF-DLM)
- 증상: 옛 main(`lcdd-local/t2`)의 pi가 끝나 keep 셸(bash)만 남고, 새 pi가 같은 탭의 다른 pane(`t29`)에 떴다. sub-agent 7개의 `parent`는 여전히 `t2`라서 새 main 밑에 묶이지 않았다.
- `parent`를 바꾸는 명령은 없다(`hc --help`에 re-parent 없음).
- 사용자 선택에 따라 세션은 건드리지 않고 `my-agents`에서 처리한다. 부모의 프로그램이 끝났으면(코어 `program`이 shell이거나 agent가 아님) 같은 탭에 있는 최상위 live agent를 **대리 부모**로 삼아 그 밑에 트리로 표시하고, 옛 main 행은 숨긴다.
- 실제 `parent`는 바뀌지 않는다. `hc ls`/`herdr-app ls`의 `sub_agents`는 여전히 옛 주소를 가리킨다. 새 main에서 `hc wait --children` 같은 부모 기반 기능을 쓰면 이 7개는 잡히지 않는다 `[추정]`.
- 대리 부모가 잡히는 조건은 옛 main과 새 main이 **같은 탭**에 있는 것이다. 새 main을 다른 탭이나 space에서 띄우면 적용되지 않는다.
- 결과: 2026-11-09 사용자가 IF-DLM 사이드바에서 새 main 아래 7개가 트리로 표시되는 것을 확인했다. 따라서 `program.shell`/`program.agent` 기반 `ended()` 판정이 실제로 동작한다.

## 확인 (보고 전 필수)
- `hc ls --json`: `parent`가 main 주소인지 확인한다.
- `herdr-app ls`: 그 터미널에 `pane`이 있고 부모와 같은 space인지 확인한다.
- `herdr-app status`: `layout=my-layout`인지 확인한다.
- 사이드바 화면은 에이전트가 볼 수 없다. 최상위 중복이 사라졌는지는 사용자 확인으로 남기고 "확인했다"고 쓰지 않는다.
- 보고에는 이름, `parent`, space, 탭 유무, layout을 적는다.

## 금지
- 사용자 목표가 트리+탭인 동안 `terminal.park`을 쓰지 않는다. `park`로 "pane 0개"를 확인하고 성공이라고 보고한 사고가 있었다.
- `space.select --id …` 플래그 형식을 쓰지 않는다.
- `layouts/.state/*.json`과 출고본 mod·layout을 직접 편집하지 않는다.
- 사용자가 준 명령이 목표와 반대 효과를 내면(예: `park`) 실행 전에 그 점을 한 줄로 알린다.

## 머신 (ssh / Add machine)
`~/.ssh/config` 별칭은 이렇게 정리돼 있다(HostName·포트는 `~/.ssh/config`에만 둔다 — 이 파일은 공개 저장소에 있다). herdr의 "Add machine"에는 별칭을 입력한다.
| ssh 별칭 | 경유 | herdr 머신 이름 |
|---|---|---|
| `lcdd-local` | 직접 | `lcdd-local` |
| `lcdd-server` | 직접 | `lcdd-server` (2026-11-11 추가, hc 0.1.19 `--install`) |
| `lcdd-cluster`, `master` | `ProxyJump lcdd-local` | `lcdd-master` (target=`lcdd-cluster`, 옛 이름 `lcdd-cluster1`) |
| `lcdd-ai-master` | `ProxyJump lcdd-local` | `lcdd-ai-master` |
- `lcdd-local`과 `lcdd-server`는 IP가 같고 포트만 다른 **별개 서버**다(hostname, machine-id 다름).
- ProxyJump 경로에서는 점프 호스트가 이름을 해석하므로 `HostName`은 IP로 쓴다. 이 Mac의 `/etc/hosts`에만 있는 `ai-master` 같은 이름은 쓰지 않는다.
- `lcdd-cluster`와 `lcdd-ai-master`는 호스트명이 둘 다 `master`지만 서로 다른 서버다(machine-id, IP 다름).
- 보류: `lcdd-cluster`/`master`를 `lcdd-master`로 통일하는 방식이 미정이다. 후보는 (1) `Host lcdd-master lcdd-cluster` 호환 별칭, (2) 완전 통일 후 herdr에서 `hc machine rm` → 재추가다.
- 2026-11-09 `herdr-app status`에서 `lcdd-ai-master`가 `UNKNOWN port 65535`로, `lcdd-local`이 timeout으로 연결 실패했다. 원인은 확인하지 못했다 `[미확인]`.

## 제약
- 머신을 넘는 `parent` 지정은 확인되지 않았다 `[미확인]`. main과 같은 머신에서 띄운다.
- 부모 프로그램이 끝나면 자식도 종료된다(`--outlive-parent`는 기본값이 아님).
- keep한 터미널은 프로그램이 사라지면 원래 명령을 재실행하지 않고 셸을 남긴다(`AGENTS.md:136`).
- peer 래퍼(`peer-ask` 등)가 내부에서 `--no-parent`를 쓰는지는 확인하지 않았다 `[미확인]`. 래퍼로 띄운 뒤 "확인" 절차를 수행한다.

## oms panel 재부착 (fork `09fbbd3`, 2026-11-15)
- 증상: panel 탭을 닫고 새 탭에서 `oms panel`을 다시 열면, tmux 안의 omo main은 옛 `HC_TERMINAL_ID`를 그대로 쥐고 있다. 그래서 새 탭이 agent로 표시되지 않고(`status=None`), main이 `hc run`으로 띄운 peer의 parent가 닫힌 터미널이 된다.
- herdr 인식은 ID가 아니라 OSC 7501이 tmux passthrough를 거쳐 attach된 클라이언트로 가는 방식이다. 문제는 omo가 idle이면 다시 보고하지 않는다는 점이다.
- 조치: 재부착하는 `oms panel`이 tmux 세션 env의 `HC_*`를 새 값으로 바꾸고, 새 탭에 마지막 Pi 상태(`@oms_pi_state`)를 OSC로 한 번 다시 보낸다. 그리고 `pi-oms-extension`이 tool을 실행하기 직전마다 세션 env의 `HC_*`를 다시 읽는다. omo는 OMS에서 resume이 막혀 있어(`FRESH_ONLY`) 재시작 대신 이 방식을 택했다.
- lcdd-master E2E: 재부착 직후 새 탭이 `app=pi idle`로 잡혔고, 턴 동안 working→idle로 바뀌었으며, `hc run` 자식의 `parent`가 새 탭으로 기록됐다.
- **한계**: 업데이트 전에 시작된 omo는 옛 extension을 쥐고 있다. 재부착한 뒤 omo에서 `/reload`(또는 재시작)를 해야 parent가 갱신된다. claude/codex main은 이 경로가 없어 여전히 옛 ID를 쓴다 `[미해결]`.
