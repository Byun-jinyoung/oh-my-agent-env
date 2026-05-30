---
description: Slack #ai-feed 채널 메시지에서 도구 링크를 수집해 Claude and Claude code.md에 분류·추가한다. v6 — v5 + Slack 증분 수집(last_run_ts).
---

# Slack #ai-feed → 도구 문서 자동 업데이트 (v6)

## 공통 원칙

- 각 URL은 **독립 트랜잭션**으로 처리. 단계별 실패 시 해당 URL만 Inbox/skip, 전체 파이프라인 진행 계속. 실패 사유는 8단계 보고에 포함.
- 사실/결과 기반 분류. 추측 금지. 모르면 Inbox.
- Slack 채널 ID: `C0AM676KUUV` (#ai-feed). 변수로 취급.

## 실행 모드

- **`apply` (기본)**: 실제 문서 수정 + 백업 생성.
- **`dry-run`**: 환경변수 `UPDATE_FEEDS_DRY_RUN=1` 또는 사용자 인자 `dry-run`. 문서 수정/백업 모두 생략, 8단계 보고에 "예정 변경 라인"만 출력.

## 데이터 스키마

각 처리 단위는 다음 record:
```
{
  raw_url, resolved_url, item_url, source_url,
  status:   RESOLVED | UNRESOLVED_SHORTLINK | LOOP_DETECTED | PERMANENT_ERROR | RETRYABLE_ERROR
  category: Skill | Plugin | MCP | Agent | Guide | Marketplace | Inbox
  classification_evidence: { root_files: [...], description: "...", stars: N }
}
```

## 0단계: 백업 (apply 모드 전용)

문서 수정 전 자동 백업:
```bash
ts=$(date +%Y%m%d-%H%M%S)
cp -p "AI_Tools/Claude/Claude and Claude code.md" \
      "AI_Tools/Claude/Claude and Claude code.md.bak.${ts}"
echo "$ts" > /tmp/update-feeds-last-run.txt
```

변경 매니페스트는 `/tmp/update-feeds-changes-${ts}.json`에 기록 (롤백/감사용):
```json
{
  "run_id": "<ts>",
  "backup_path": "AI_Tools/Claude/Claude and Claude code.md.bak.<ts>",
  "added": [{"section": "Skills", "line": "...", "item_url": "..."}, ...],
  "skipped_duplicates": [...],
  "failed": [...]
}
```

dry-run 모드면 0단계 스킵.

## 1단계: Slack 수집 (증분)

**증분 윈도 결정**:
```bash
if [ -f /tmp/update-feeds-last-run.txt ]; then
  last_ts=$(cat /tmp/update-feeds-last-run.txt)
  # ts 형식 YYYYMMDD-HHMMSS → YYYY-MM-DD 변환
  last_date=$(echo "$last_ts" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2}).*/\1-\2-\3/')
  # 안전 마진: 마지막 실행 날짜 하루 전부터 (경계 메시지 누락 방지)
  fetch_date=$(date -j -v-1d -f '%Y-%m-%d' "$last_date" +'%Y-%m-%d' 2>/dev/null || echo "$last_date")
else
  fetch_date=""  # 첫 실행: 전체 fetch
fi
```

**Slack 호출**:
```
mcp__slack-server__conversations_search_messages
  search_query: "in:#ai-feed"
  limit: 100
  filter_date_after: "<fetch_date>"   # last_run_ts 있을 때만 전달
```

- `filter_in_channel` 버그(ID/이름 0건) → search_query만 사용, channel.id == `C0AM676KUUV` 메시지 수동 필터.
- 응답 항상 sandbox로 처리: `mcp__plugin_context-mode_context-mode__ctx_execute_file`.
- 마지막 메시지가 limit-1번째이고 `has_more=true`인 경우만 `cursor` 추가 요청. 그 외 1회로 종료.
- Slack 5xx/429 시 exponential backoff(2s/4s/8s) 최대 3회 후 fail.
- **첫 실행 (last_run_ts 부재)**: 안전 모드로 100개 전체 fetch. 다음 실행부터 증분.
- last_run_ts는 0단계에서 갱신됨 (apply 모드만). dry-run은 갱신 안 함.

## 2단계: URL 추출

각 메시지에서 다음 우선순위로 raw_url 추출:
1. `attachments[*].from_url`, `attachments[*].original_url`
2. `text` 필드 `<URL>` 또는 `<URL|label>` 패턴
3. `text` 필드 bare URL
4. `attachments[*].text` 안의 `<https://t.co/XXX>` 등 단축 URL

한 메시지에 여러 raw_url이 있으면 각각 독립 record로 처리.

## 3단계: URL 정규화 + 단축 URL 펼치기

**정규화** (중복 검사 키 생성용):
- `?...`, `#...` 제거
- 후행 슬래시 제거
- 호스트 소문자

**단축 URL 펼치기** (해당 호스트만): `t.co`, `bit.ly`, `lnkd.in`, `buff.ly`, `share.google`

```bash
resolved=$(curl -sIL -o /dev/null --max-time 8 --max-redirs 10 \
  -A "Mozilla/5.0" -w '%{url_effective}' "$URL")
exit_code=$?
```

**상태 분류**:
- `exit_code=0` AND 결과가 단축 도메인 아님 → `RESOLVED`
- `exit_code=0` AND 결과가 단축 도메인 → 1회 재귀(총 3회). 3회 후에도 단축이면 `LOOP_DETECTED`
- `exit_code=28` (timeout) 또는 `52` (empty reply) → `RETRYABLE_ERROR` (1회 재시도 후 실패 시 원본 URL을 `item_url`로 두고 진행)
- TLS/4xx/5xx → `PERMANENT_ERROR` (원본 URL을 `item_url`로 두고 진행)

**보안**: 펼친 URL은 정규식 화이트리스트 통과만 후속 단계로 전달:
```
^https?://[A-Za-z0-9.\-]+\.[A-Za-z]{2,}(:[0-9]+)?(/[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]*)?$
```
통과 못 하면 `PERMANENT_ERROR`로 분류.

## 4단계: 도메인 라우팅 + 중복 검사

**도메인별 `item_url`/`source_url` 결정**:

| 도메인 패턴 | `item_url` | `source_url` |
|------------|-----------|-------------|
| `github.com/<owner>/<repo>` | resolved_url | — |
| `x.com` / `twitter.com` | attachments.text 안 단축 URL 펼친 결과가 GitHub repo면 그것을, 아니면 X URL | X URL (item과 다를 때만) |
| `www.threads.com` / `threads.net` | 4.5단계 참조 (fast path: attachments.text URL, fallback: Playwright 본문/URL 추출) | Threads URL (item과 다를 때만) |
| 기타 (블로그/news/youtube) | resolved_url | — |

**중복 검사 키 (2단)**:
1. **resolved_url_normalized** — 기존 문서의 모든 URL을 정규화해 인덱스. raw/item/source 어느 경로로 들어와도 동일 엔티티 매칭.
2. **플랫폼 고유키**:
   - GitHub: `owner/repo` (소문자, `.git`/`tree/...` 제거)
   - X: status ID — `^https?://(?:[^/]+\.)?(?:x|twitter)\.com/(?:[^/]+/)?(?:i/)?status/(\d+)`
   - Threads: (handle, post_id) — `^https?://(?:www\.)?threads\.(?:com|net)/@([^/]+)/post/([A-Za-z0-9_-]+)`

중복 발견 시 record 폐기 + 8단계 보고에 `중복` 카운트.

## 4.5단계: Threads 본문 추출 (Playwright MCP)

Threads URL record는 본문이 React SPA로 렌더링되어 curl로 추출 불가능 (v4 실증 확인됨). `@playwright/mcp` 사용 (`~/.claude.json` mcpServers에 `playwright` 등록).

**호출 순서** (우선순위):
1. **fast path**: `attachments[0].text`에 외부 URL 있으면 → 그것을 `item_url`로, 4단계 라우팅 그대로
2. **fallback (Playwright)**: fast path 실패 시에만 호출

**Playwright 추출 절차** (실증된 셀렉터):
```javascript
await page.goto(threadsUrl, { waitUntil: 'domcontentloaded', timeout: 25000 });
await page.waitForTimeout(1500);  // JS 렌더 대기

const ogDesc = await page.$eval('meta[property="og:description"]', el => el.content).catch(() => null);
const mainText = await page.evaluate(() => {
  const c = document.querySelector('[data-pressable-container]');
  return c ? c.innerText : null;
});
const externalUrls = await page.evaluate(() => {
  return [...new Set(Array.from(document.querySelectorAll('a[href]'))
    .map(a => a.href)
    .filter(u => u.startsWith('http')
      && !u.match(/threads\.(com|net)|instagram\.com|facebook\.com|meta\.com|fb\.com/))
  )].slice(0, 10);
});
```

**결과 분기**:
- `externalUrls`에 GitHub repo 있음 → 그것이 `item_url`, Threads URL은 `source_url`
- `externalUrls`에 비-GitHub URL만 있음 → first URL이 `item_url`, Threads URL은 `source_url`
- `externalUrls` 비어있음 → 본문(`og_description`/`main_text`) 키워드 휴리스틱:
  - GitHub/repo/skill/plugin/MCP/agent/CLI/Claude/Codex 키워드 포함 → **Inbox에 본문 발췌 등록** (사용자 확인 필요 플래그)
  - 그 외 (개인 일기/뉴스/광고/노하우 글) → **record 폐기**

**비용**: 페이지당 ~3.5초 (실측). 100건이면 ~6분.

**실패 처리**:
- timeout / MCP 미응답 → 1회 재시도 후 record 폐기 (8단계 보고)
- Meta 향후 차단 시 → fast path만 사용 (v4 동작으로 fallback)

## 5단계: GitHub repo 분류 (gh api)

`item_url`이 GitHub repo인 record만 적용.

**OWNER/REPO 추출 (보안)**:
```bash
re='^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)(/|$)'
if [[ "$item_url" =~ $re ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]%.git}"
else
  category=Inbox; reason=invalid_github_url
fi
```

```bash
gh api "repos/$OWNER/$REPO" --jq '{stars: .stargazers_count, language, description, default_branch}'
gh api "repos/$OWNER/$REPO/contents" --jq '
  [.[] | .name]
  | map(select(. == "SKILL.md" or . == ".claude-plugin" or . == ".mcp.json"
              or . == "manifest.json" or . == "CLAUDE.md" or . == "AGENTS.md"
              or . == "CURSOR.md" or . == "GEMINI.md" or . == "bin"
              or . == "pyproject.toml" or . == "package.json"))
'
```

`gh api` 401/403/429 → 1회 재시도, 그래도 실패 시 Inbox + reason 기록.

**분류 — first-match-wins (top-to-bottom)**:

1. 루트에 `.claude-plugin/` → **Plugin**
2. 루트에 `.mcp.json` OR description에 "MCP server"/"Model Context Protocol" → **MCP**
3. 루트에 `SKILL.md` → **Skill**
4. 루트에 `manifest.json` AND description에 "Obsidian" → **Inbox** (Obsidian community plugin)
5. (`bin/` OR `pyproject.toml[scripts]` OR `package.json.bin`) AND README에 `--help`/`init`/`run` CLI usage → **Agent/Automation**
6. description에 `awesome-`/`curated list`/`collection` → **Marketplace**
7. README가 본질적으로 문서/가이드 (코드/CLI 진입점 부재) → **Guide**
8. 위 매칭 안 됨 → **Inbox** (`reason=unmatched_signals`)

`classification_evidence`에 매칭 신호(루트 파일명/description 키워드)를 기록.

## 6단계: Codex 교차검증

분류 record들을 묶어 1회 호출:
```
mcp__codex-mcp__ask_codex
  prompt: |
    분류 기준: Skill / Plugin / MCP / Agent / Guide / Marketplace / Inbox
    각 항목에 CORRECT / WRONG(올바른 카테고리) / UNSURE.
    [item_url, Claude 분류안, classification_evidence]
  reasoning_effort: low
  background: true
```

**Turn-1 결과**:
- CORRECT → 분류 확정
- WRONG(<category>) → turn-2 진행
- UNSURE → **Inbox**

**Turn-2 종료 (정량)**:
- Turn-2도 동일 라벨 반복 → Codex 의견 채택
- Turn-2가 다른 라벨 (Codex 흔들림) → **Inbox**
- Codex가 turn-2에서 (a) 루트 파일 경로 또는 (b) repo description 인용을 **최소 2개** 제시 → 채택. 그 외 → **Inbox**

이미 문서에 등록된 항목은 4단계에서 폐기되므로 6단계에 도달 안 함 (분류 drift 방지).

## 7단계: 문서 업데이트

`apply` 모드: 대상 `AI_Tools/Claude/Claude and Claude code.md`에 항목 추가.
`dry-run` 모드: 변경 예정 라인을 8단계 보고로 출력, **파일 수정 안 함**.

**항목 형식**:
```markdown
- [repo명 또는 도구명](item_url) — 한 줄 설명 (stars, 언어). 소개: [source_url](source_url) #tag *(분류 근거 + Codex 합의)*
```
`source_url == item_url`이거나 비어 있으면 "소개: ..." 생략.

**카테고리 → 섹션 매핑**:
- Skill → `### Skills`
- Plugin → `### Plugins`
- MCP → `### MCP`
- Agent → `## 에이전트 & 자동화`
- Marketplace → `## 마켓플레이스 & 디렉토리`
- Guide → `## 가이드 & 참고`
- Inbox → `## Inbox`

**태그**: 카테고리 = 태그 (`#skill`, `#plugin`, `#mcp`, `#agent`, `#marketplace`, `#guide`). Inbox 항목 태그 생략. Obsidian 관련 보조 태그 `#obsidian` 허용.

각 추가 항목을 `/tmp/update-feeds-changes-${ts}.json`의 `added[]`에 기록 (apply 모드만).

## 8단계: 결과 보고

```
실행 모드: apply | dry-run
Run ID: <ts>
백업: AI_Tools/Claude/Claude and Claude code.md.bak.<ts>  (apply 모드만)
매니페스트: /tmp/update-feeds-changes-<ts>.json  (apply 모드만)

신규 추가: <count>건 (Skill X, Plugin X, MCP X, Agent X, Guide X, Marketplace X, Inbox X)
  - <item_url>  ← Codex 합의
  - ...

중복 스킵: <count>건
  - <raw_url>  ← <기존 doc 항목>

처리 실패: <count>건
  - <raw_url>  ← status=<...>, reason

Threads 폐기: <count>건 (attachments.text URL 부재)

단축 URL 매핑:
  - <X/Threads ID>: <단축 URL> → <resolved>

Codex 검증 → Inbox: <count>건
  - <item_url>  ← Claude(<cat>) / Codex(<cat>)

[dry-run only] 예정 변경 라인:
  ## 섹션명
  + <항목 라인 1>
  + <항목 라인 2>
```

## 부록 A: 롤백 절차

**전체 롤백** (직전 run 되돌리기):
```bash
ts=$(cat /tmp/update-feeds-last-run.txt)
mv "AI_Tools/Claude/Claude and Claude code.md.bak.${ts}" \
   "AI_Tools/Claude/Claude and Claude code.md"
```

**부분 롤백** (특정 항목만 제거):
1. `/tmp/update-feeds-changes-${ts}.json`의 `added[]`에서 제거할 항목 식별 (item_url 기준)
2. 해당 라인을 `AI_Tools/Claude/Claude and Claude code.md`에서 `grep -F -v` 또는 Edit 도구로 제거
3. 매니페스트의 `added[]`에서 해당 항목 삭제

**git 활용** (vault가 git repo인 경우):
```bash
git diff "AI_Tools/Claude/Claude and Claude code.md"            # 변경 확인
git checkout -- "AI_Tools/Claude/Claude and Claude code.md"     # 전체 되돌리기
```

**백업 파일 정리** (>30일 된 백업):
```bash
find "AI_Tools/Claude/" -name "Claude and Claude code.md.bak.*" -mtime +30 -delete
```

## 부록 B: 사전조건

- `gh` CLI 인증 (`gh auth status`). 미인증 시 unauthenticated rate limit 60/hr.
- Slack MCP, codex-mcp 활성.
- context-mode MCP 활성 (sandbox 파싱).
- Gemini MCP 현재 미활성 — 재연결 시 6단계에 3자 검증 추가 가능.

## 부록 C: 미구현 / 향후

- ~~**Slack 증분 수집** (`last_run_ts` 기반)~~ → v6에서 1단계 `filter_date_after`로 구현.
- **Gemini 3자 검증**: MCP 재연결 후 6단계에 병렬 추가.
- **Threads 추출 캐시**: 동일 Threads URL을 여러 번 처리하지 않도록 `/tmp/threads-cache.json`에 (handle, post_id) → 본문/URL 매핑 저장 검토.
