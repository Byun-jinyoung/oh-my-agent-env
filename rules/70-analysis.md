# 결과·실험 분석 (70-analysis)

연구/ML 작업에서 실험 결과·측정값·로그를 해석할 때의 규칙.

## 측정 우선

- 결과는 추측하지 말고 실제 출력(metric, 로그, 파일)으로 확인한다.
- 수치를 인용할 때 출처를 함께 적는다: run id, config, split, seed, commit.
- 단일 수치만 보고하지 말고 비교 기준(baseline, 이전 run, 목표치)을 함께 제시한다.

## 비교의 공정성

- 비교하는 run들이 같은 데이터 split·전처리·평가 코드를 썼는지 먼저 확인한다.
- 차이가 우연 범위인지(분산, seed 변동) 구분한다. 1회 측정으로 우열을 단정하지 않는다.
- metric 방향(높을수록 좋음/나쁨)을 파일명·관례로 추측하지 말고 확인한다.

## 해석의 절제

- 상관과 인과를 구분한다. 성능 변화의 원인을 단정하기 전에 대안 가설을 나열한다.
- 결론에는 근거 + 반대 가설 + 신뢰도(높음/중간/낮음)를 함께 적는다.
- 데이터 누수(leakage) 의심 신호(비현실적 점수, train/val 경계 모호)를 먼저 점검한다.

## 기록

- 분석 결과는 시간이 지나도 결정 근거가 살아야 하므로 vault/문서에 남긴다.
- 큰 결과 덤프는 문서에 붙이지 말고 출력 파일을 링크한다.
- 분석으로 내린 결정은 무엇을·왜·어떤 근거로 정했는지 함께 적는다.

## 도구 — 위 규칙을 지키는 수단

위 항목들은 오래 규범으로만 존재했고 강제하는 장치가 없었다. `oma-lab`이
그 장치이며, PATH에 있다. 규칙과 명령의 대응은 다음과 같다. **훈련·평가
명령은 직접 실행하지 말고 `oma-lab run --` 뒤에 붙인다.**

| 위 규칙 | 명령 |
|---|---|
| 출처(run id·commit·split)를 함께 적는다 | `oma-lab run --metrics k=v -- <cmd>` — 커밋·dirty·exit·소요시간을 한 행으로 기록 |
| 비교 기준을 함께 제시한다 | `oma-lab top --metric KEY` — 최고 baseline을 기억이 아닌 조회로 |
| 같은 split을 썼는지 먼저 확인한다 | `oma-lab data register` / `data check` |
| 누수 신호를 먼저 점검한다 | `oma-lab data leakage --name N` — 확인 불가하면 exit 2 |
| 결정 근거가 오래 살아야 한다 | `oma-lab capsule save` / `capsule whence FILE` |

세션이 갈려도 남아야 하는 것들:

- 이미 깨진 것으로 판명된 명령은 `oma-lab fail check`로 먼저 확인한다.
  동일 트리에서의 재시도는 exit 3으로 막힌다.
- 실험 id는 `oma-lab board claim --id NAME`으로 선점한다. 두 세션이 같은
  실험을 중복 실행하는 것을 막는다.
- Slurm으로 던진 job은 `sbatch`의 exit 0이 학습의 성공을 뜻하지 않는다.
  `oma-lab reconcile apply`로 실제 종료 상태를 회수해야 ledger가 거짓말을
  멈춘다.

도구가 없다고 나오면 `~/.oh-my-agent-env/setup.sh sync`의 `[5b]` 단계가
`~/.local/bin/oma-lab` 링크를 만든다.
