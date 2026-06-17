#!/usr/bin/env node
// Stop hook: enforce rule 6 (verify before declaring done) — but ONLY the
// observable proxy that exists: "this turn edited files but ran no verification
// command afterward." This does NOT enforce general work attitude (no
// observable signal for that); it only gates file-editing turns.
//
// Decision logic (defaults to ALLOW on any error/uncertainty — never trap the user):
//   - stop_hook_active === true  -> ALLOW (circuit breaker: block at most once/chain)
//   - edited this turn AND no Bash/ctx_execute/python_repl AFTER the last edit
//     AND final assistant text lacks an escape marker -> BLOCK
//   - otherwise -> ALLOW
// Escape marker (honest opt-out for note/doc edits needing no run-verification):
//   put "검증생략:", "검증불가:", or "NO-VERIFY:" in the final message.
const fs = require('fs');

const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);
const MARKER = /검증생략:|검증불가:|NO-VERIFY:/;

function isVerify(name) {
  return name === 'Bash' || name.includes('ctx_execute') || name.includes('python_repl');
}
function isRealPrompt(d) {
  if (d.type !== 'user') return false;
  const m = d.message || {};
  if (m.role !== 'user') return false;
  const c = m.content;
  if (typeof c === 'string') return c.trim() !== '';
  if (Array.isArray(c)) return c.some((it) => it && it.type === 'text');
  return false;
}
function allow() {
  process.exit(0);
}

const stdinTimeout = setTimeout(() => process.exit(0), 5000);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (input += c));
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const payload = JSON.parse(input || '{}');
    if (payload.stop_hook_active === true) return allow(); // circuit breaker
    const tpath = payload.transcript_path;
    if (!tpath || !fs.existsSync(tpath)) return allow();

    const lines = fs.readFileSync(tpath, 'utf8').split('\n').filter(Boolean);
    const entries = [];
    for (const l of lines) {
      try { entries.push(JSON.parse(l)); } catch (e) { entries.push(null); }
    }
    // turn boundary = last genuine user prompt
    let boundary = -1;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i] && isRealPrompt(entries[i])) boundary = i;
    }

    let lastEditIdx = -1;
    let lastVerifyIdx = -1;
    const editedFiles = [];
    let lastText = '';
    for (let i = boundary + 1; i < entries.length; i++) {
      const d = entries[i];
      if (!d || d.type !== 'assistant') continue;
      const content = (d.message || {}).content || [];
      for (const it of content) {
        if (!it || typeof it !== 'object') continue;
        if (it.type === 'text' && typeof it.text === 'string') lastText = it.text;
        if (it.type === 'tool_use') {
          const name = it.name || '';
          if (EDIT_TOOLS.has(name)) {
            lastEditIdx = i;
            const fp = (it.input || {}).file_path;
            if (fp) editedFiles.push(fp);
          }
          if (isVerify(name)) lastVerifyIdx = i;
        }
      }
    }

    const edited = lastEditIdx >= 0;
    const verifiedAfterEdit = lastVerifyIdx > lastEditIdx;
    const escaped = MARKER.test(lastText);

    if (edited && !verifiedAfterEdit && !escaped) {
      const files = [...new Set(editedFiles)].slice(0, 5).join(', ') || '(파일 경로 미상)';
      const reason =
        '[검증 게이트] 이번 턴에 파일을 편집했지만(' + files + ') ' +
        '편집 이후 검증 명령을 실행하지 않았습니다. 규칙 6: 변경에 맞는 최소 검증' +
        '(테스트/lint/`bash -n`/`python3 -m json.tool`/실행 등)을 실제로 돌려 출력을 확인하세요. ' +
        '실행 검증이 불필요·불가한 변경(예: 노트/문서)이면 마지막 메시지에 ' +
        '"검증생략: <이유>"를 적으면 통과합니다.';
      process.stdout.write(JSON.stringify({ decision: 'block', reason }));
      return process.exit(0);
    }
  } catch (e) {
    // never trap the user
  }
  allow();
});
