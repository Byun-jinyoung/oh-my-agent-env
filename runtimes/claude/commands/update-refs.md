---
description: Slack #reference-feed 채널에서 논문·아티클·X 포스트 링크를 수집하여 Inbox/refs/*.md(관심사별)에 분류·추가한다. v2 — t.co 펼치기 + Playwright Threads/X 본문 추출 + 논문 API 강화 + last_run_ts 증분 수집 + Codex 교차검증.
---

# Slack #reference-feed → 리딩 큐 자동 업데이트 (v2)

## 공통 원칙

- 각 URL은 **독립 트랜잭션**으로 처리. 단계별 실패 시 해당 URL만 Inbox로 보내고 전체 진행 계속.
- 사실/결과 기반 분류. 추측 금지. 모르면 "(제목 미확인)" 또는 `#기타` 태그.
- Slack 채널 ID: `C0AMW3BMDPT` (#reference-feed). 변수로 취급.

## 실행 모드

- **`apply` (기본)**: 실제 파일 수정 + 백업.
- **`dry-run`**: `UPDATE_REFS_DRY_RUN=1` 또는 인자 `dry-run`. 변경 예정 라인만 출력, 파일 수정 안 함.

## 데이터 스키마

```
{
  raw_url, resolved_url, item_url, source_url,
  paper_title: 추출된 논문/연구 제목 (없으면 null)
  category: 구조예측 | 단백질설계 | 분자생성 | 생성이론 | LLM | 기타
  date: YYYY-MM-DD (Slack ts 변환)
  poster: X/Threads 작성자 핸들 (해당 시)
  status: RESOLVED | UNRESOLVED_SHORTLINK | LOOP_DETECTED | PERMANENT_ERROR | RETRYABLE_ERROR
}
```

## 0단계: 백업 (apply 모드)

```bash
ts=$(date +%Y%m%d-%H%M%S)
for f in Inbox/refs/*.md Inbox/reference-feed-index.md; do
  cp -p "$f" "$f.bak.${ts}"
done
echo "$ts" > /tmp/update-refs-last-run.txt
```

변경 매니페스트: `/tmp/update-refs-changes-${ts}.json`.

## 1단계: Slack 증분 수집

```bash
if [ -f /tmp/update-refs-last-run.txt ]; then
  last_ts=$(cat /tmp/update-refs-last-run.txt)
  last_date=$(echo "$last_ts" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2}).*/\1-\2-\3/')
  fetch_date=$(date -j -v-1d -f '%Y-%m-%d' "$last_date" +'%Y-%m-%d' 2>/dev/null || echo "$last_date")
else
  fetch_date=""
fi
```

```
mcp__slack-server__conversations_search_messages
  search_query: "in:#reference-feed"
  limit: 100
  filter_date_after: "<fetch_date>"
```

- channel.id == `C0AMW3BMDPT` 수동 필터.
- 응답 항상 sandbox(`ctx_execute_file`)로 처리.
- has_more=true 시 cursor 추가 요청.
- 5xx/429 시 exponential backoff(2s/4s/8s) 3회.

## 2단계: URL 추출

각 메시지에서 우선순위:
1. `attachments[*].from_url`, `original_url`
2. `text` 필드 `<URL>`/`<URL|label>`
3. `text` bare URL
4. `attachments[*].text` 안의 `<https://t.co/XXX>` 단축 URL

한 메시지 여러 URL → 각 독립 record.

## 3단계: URL 정규화 + 단축 URL 펼치기

**정규화**: query/fragment 제거, 후행 슬래시 제거, 호스트 소문자.

**단축 URL 펼치기** (해당 호스트): `t.co`, `bit.ly`, `lnkd.in`, `buff.ly`, `share.google`, `tinyurl.com`, `doi.org`

```bash
resolved=$(curl -sIL -o /dev/null --max-time 8 --max-redirs 10 \
  -A "Mozilla/5.0" -w '%{url_effective}' "$URL")
```

상태: RESOLVED / LOOP_DETECTED (3회 재귀 후) / RETRYABLE_ERROR (timeout) / PERMANENT_ERROR (TLS/4xx/5xx).

**예외**: `doi.org`는 펼치기 후 출판사 사이트(nature/biorxiv/...)에 도달 → 그것을 resolved_url로 사용. 단 메타데이터 조회용 `doi` 자체는 별도 보관(논문 제목 API용).

**보안 화이트리스트**: `^https?://[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(:[0-9]+)?(/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?$` 통과 못 하면 PERMANENT_ERROR.

## 4단계: 도메인 라우팅 + 중복 검사

| 도메인 | 처리 |
|--------|------|
| `arxiv.org`, `biorxiv.org`, `chemrxiv.org`, `nature.com`, `science.org`, `pnas.org`, `pubmed.ncbi.nlm.nih.gov`, `doi.org`, `acs.org`, `aps.org`, `cell.com` | 📄 논문 → 5단계 (제목 API) |
| `github.com` | 🐙 연구 레포 (description만 짧게) |
| `x.com`, `twitter.com` | 🐦 X 포스트 → 5.5단계 (attachment.text/t.co/Playwright로 논문 추출) |
| `www.threads.com`, `threads.net` | 🐦 Threads → 5.5단계 (Playwright 본문) |
| 기타 | 📝 아티클 (attachments.title 사용) |

**중복 검사 (2단)**:
1. 정규화 URL 인덱스 (`Inbox/refs/*.md` 전체 + `reference-feed-index.md`)
2. 플랫폼 키:
   - arXiv: `arxiv_id` (`\d{4}\.\d{4,5}` 또는 `\d{7}\.\d{4,5}`)
   - bioRxiv/chemRxiv: `doi`
   - X: status ID
   - Threads: (handle, post_id)

## 5단계: 📄 논문 제목 추출 (API)

| 호스트 | API |
|--------|-----|
| arXiv | `attachments[0].title` 우선 → 없으면 `https://export.arxiv.org/api/query?id_list={id}` → `<title>` |
| bioRxiv | `https://api.biorxiv.org/details/biorxiv/{doi}` → `collection[0].title` |
| chemRxiv | `https://chemrxiv.org/engage/api-gateway/chemrxiv/public/publication?term={doi}` → `itemHits[0].item.title` (Semantic Scholar API는 이 도메인 누락 잦음 — direct API 우선) |
| Nature/Science/Cell | WebFetch 차단 환경 → `attachments[0].title` 사용. 실패 시 "(제목 미확인)" |
| DOI 일반 | `https://api.crossref.org/works/{doi}` → `message.title[0]` |

모두 실패 시 "(제목 미확인)" 표시 + `#기타` 태그 후보로 강등.

## 5.5단계: X/Threads 본문 추출 (Playwright MCP)

논문/연구를 소개하는 X/Threads 포스트가 핵심. `@playwright/mcp` 사용.

**호출 순서**:
1. **fast path**: `attachments[0].text`에 논문 URL(arxiv/biorxiv/chemrxiv/doi)이 있으면 → 그것을 `item_url`로, 5단계 API 호출
2. **fast path 2**: t.co 펼친 결과가 논문 URL이면 → 동일
3. **fallback (Playwright)**: attachments 정보 부족 시

**Playwright Threads 추출** (v5 검증):
```javascript
await page.goto(url, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(1500);
const og = await page.$eval('meta[property="og:description"]', el => el.content).catch(() => null);
const main = await page.evaluate(() => {
  const c = document.querySelector('[data-pressable-container]');
  return c ? c.innerText : null;
});
const externalUrls = await page.evaluate(() => {
  return [...new Set(Array.from(document.querySelectorAll('a[href]'))
    .map(a => a.href)
    .filter(u => u.startsWith('http')
      && !u.match(/threads\.(com|net)|instagram\.com|facebook\.com|meta\.com/)))].slice(0, 10);
});
```

**Playwright X 추출**:
```javascript
const tweetText = await page.$eval('[data-testid="tweetText"]', el => el.innerText).catch(() => null);
const tcoUrls = await page.evaluate(() =>
  Array.from(document.querySelectorAll('a[href*="t.co/"]')).map(a => a.href)
);
// tcoUrls를 다시 펼침 (3단계 재호출)
```

**결과 분기**:
- 논문 URL 발견 → 5단계 API로 제목 추출
- 외부 URL 없음 + 본문이 논문 제목/저자 패턴 (예: 영어 대문자 첫 단어 + 콜론) → 본문에서 제목 추출 시도
- 분류 불가 → `#기타` 태그로 항목 등록 (본문 요약 짧게)

## 6단계: 관심사 분류 (5개 + 기타)

논문 제목 + abstract 키워드로 자동 분류:

| 태그 | 키워드 |
|------|--------|
| `#구조예측` | structure prediction, AlphaFold, RoseTTAFold, fold, conformation, contact map, distogram, residue |
| `#단백질설계` | de novo design, antibody design, protein design, inverse folding, ProteinMPNN, RFdiffusion |
| `#분자생성` | molecular generation, docking, ligand, small molecule, drug design, fragment, ADMET |
| `#생성이론` | flow matching, diffusion model, score matching, SDE, ODE, normalizing flow, manifold, Riemannian, OT, optimal transport |
| `#LLM` | transformer, attention, positional encoding, RoPE, KV cache, in-context learning, ICL, LoRA, RAG |
| `#기타` | 위 어디에도 매칭 안 됨 |

복수 태그 가능 (예: protein design + diffusion → `#단백질설계` + `#생성이론`).

## 6.5단계: Codex 교차검증

분류 record를 묶어 1회 호출:
```
mcp__codex-mcp__ask_codex
  prompt: |
    각 논문의 관심사 분류 (구조예측/단백질설계/분자생성/생성이론/LLM/기타) 검증.
    CORRECT / WRONG(올바른 태그) / UNSURE 한 줄.
    [paper_title, abstract_snippet, Claude 분류안]
  reasoning_effort: low
  background: true
```

**합의**:
- CORRECT → 분류 확정
- WRONG → Codex 의견 turn-2 검증
- UNSURE → `#기타`로 강등

## 7단계: 문서 업데이트

**대상 파일** (태그별):
- `Inbox/refs/구조예측.md`
- `Inbox/refs/단백질설계.md`
- `Inbox/refs/분자생성.md`
- `Inbox/refs/생성이론.md`
- `Inbox/refs/LLM.md`
- `Inbox/refs/기타.md`

복수 태그 항목은 해당 파일 **모두**에 추가.

**항목 형식**:
```markdown
- [ ] [논문 제목](item_url) — 한 줄 요약 | @poster(X/Threads만) | `YYYY-MM-DD`
```

X/Threads 소개 포스트는 `item_url`이 논문 URL, `source_url`을 별도 표기:
```markdown
- [ ] [논문 제목](https://arxiv.org/abs/xxxx) — 요약. 소개: [X 2058...](https://x.com/i/status/...) | @poster | `YYYY-MM-DD`
```

`apply` 모드만 파일 수정, 매니페스트에 기록.

**마스터 인덱스 갱신** (`Inbox/reference-feed-index.md`):
- 관심사 파일별 건수 업데이트
- "최근 추가" 섹션에 상위 5건 기재
- "마지막 업데이트" 날짜 갱신

## 8단계: 결과 보고

```
실행 모드: apply | dry-run
Run ID: <ts>
백업: Inbox/refs/*.md.bak.<ts>  (apply 모드만)
매니페스트: /tmp/update-refs-changes-<ts>.json

신규 추가: <count>건 (구조예측 X, 단백질설계 X, 분자생성 X, 생성이론 X, LLM X, 기타 X)
중복 스킵: <count>건
제목 미확인: <count>건 (API 실패, 출판사별 카운트)
처리 실패: <count>건
X/Threads → 논문 매핑:
  - <post_id>: <단축/Playwright> → <논문 URL> | <제목>
Codex 검증 → 기타 강등: <count>건
```

## 부록 A: 롤백 절차

```bash
ts=$(cat /tmp/update-refs-last-run.txt)
for f in Inbox/refs/*.md Inbox/reference-feed-index.md; do
  if [ -f "$f.bak.${ts}" ]; then
    mv "$f.bak.${ts}" "$f"
  fi
done
```

부분 롤백: `/tmp/update-refs-changes-${ts}.json`의 `added[]` 참조해 Edit 도구로 라인 제거.

## 부록 B: 사전조건

- `~/.claude.json` mcpServers에 `slack-server`, `codex-mcp`, `playwright` 등록.
- context-mode MCP 활성.
- `curl`, `gh` (선택, 연구 레포 분석용).
- arXiv/bioRxiv/Crossref API는 인증 불필요.

## 부록 C: 미구현

- **Nature/Science/Cell 본문 본문 추출**: WebFetch 차단 환경에서 attachments.title 의존. 향후 ctx_fetch_and_index로 대체 검토.
- **chemRxiv API 안정성**: Semantic Scholar 누락 잦음 — direct API 시도하나 응답 형식 변경 시 대비 미흡.
- **abstract 기반 분류 정확도**: 키워드 매칭만 사용. 향후 LLM 기반 분류기 도입 검토.
