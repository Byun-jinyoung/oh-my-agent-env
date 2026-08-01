#!/usr/bin/env node
// Stop hook: enforce rule 3's machine-observable proxy — "this turn did
// substantial work but the session never used a ToDo tool."
// Measured basis: with prompt-template alone, ToDo tools were used in only
// 17/4,240 template sessions; injection alone does not move this.
// Condition (cross-reviewed): current turn has (edits >= 2 && tool calls >= 8)
// OR tool calls >= 20, AND the whole session has zero
// TaskCreate/TaskUpdate/TodoWrite calls. Blocks once per chain
// (stop_hook_active circuit breaker). Escape: final assistant message
// contains "단일작업:". Defaults to ALLOW on any error — never trap the user.
const fs = require('fs');

const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);
const TODO_TOOLS = new Set(['TaskCreate', 'TaskUpdate', 'TodoWrite']);
const MARKER = /단일작업:/;
const MIN_EDITS = 2;
const MIN_CALLS_WITH_EDITS = 8;
const MIN_CALLS_ALONE = 20;

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

    const entries = [];
    for (const l of fs.readFileSync(tpath, 'utf8').split('\n')) {
      if (!l) continue;
      try { entries.push(JSON.parse(l)); } catch (e) {}
    }
    let boundary = -1;
    for (let i = 0; i < entries.length; i++) {
      if (isRealPrompt(entries[i])) boundary = i;
    }

    let sessionTodo = 0; // whole session — an existing ToDo workflow counts
    let turnEdits = 0;
    let turnCalls = 0;
    let lastText = '';
    for (let i = 0; i < entries.length; i++) {
      const d = entries[i];
      if (!d || d.type !== 'assistant') continue;
      for (const it of (d.message || {}).content || []) {
        if (!it || typeof it !== 'object') continue;
        if (it.type === 'tool_use') {
          const name = it.name || '';
          if (TODO_TOOLS.has(name)) sessionTodo++;
          if (i > boundary) {
            turnCalls++;
            if (EDIT_TOOLS.has(name)) turnEdits++;
          }
        }
        if (i > boundary && it.type === 'text' && typeof it.text === 'string') lastText = it.text;
      }
    }

    const substantial =
      (turnEdits >= MIN_EDITS && turnCalls >= MIN_CALLS_WITH_EDITS) ||
      turnCalls >= MIN_CALLS_ALONE;
    if (substantial && sessionTodo === 0 && !MARKER.test(lastText)) {
      const reason =
        '[ToDo 게이트] 이번 턴에 실질 작업(편집 ' + turnEdits + '회, 도구 호출 ' + turnCalls +
        '회)을 했지만 이 세션에서 ToDo 도구(TaskCreate/TaskUpdate)를 한 번도 사용하지 않았습니다. ' +
        '규칙 3: 작업을 단순화·분해해 TaskCreate로 ToDo list를 만들고 단계별로 진행·갱신하세요. ' +
        '정말 분해가 불필요한 단일 작업이면 마지막 메시지에 "단일작업: <이유>"를 적으면 통과합니다.';
      process.stdout.write(JSON.stringify({ decision: 'block', reason }));
      return process.exit(0);
    }
  } catch (e) {
    // never trap the user
  }
  allow();
});
