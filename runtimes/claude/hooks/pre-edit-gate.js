#!/usr/bin/env node
// PreToolUse(Edit|Write|MultiEdit|NotebookEdit) hook: surface the edit-time
// checklist at the exact moment of file modification — the point where
// process rules are most often skipped.
//
// Reminder only (non-blocking). There is no machine-observable "ToDo" signal
// in this environment (no ~/.claude/todos, no TodoWrite tool), so a hard
// "block edits until a ToDo exists" gate would be unreliable and would
// false-block legitimate edits. This re-injects the relevant rules instead.
const stdinTimeout = setTimeout(() => process.exit(0), 5000);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => (input += c));
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const checklist = [
      '편집 전 체크 (반복작업 방지):',
      '1) 이 파일을 Read/이해했고, 바꾸기 전 기존 동작을 관찰했는가?',
      '2) 이 편집이 요청 범위 안인가? 무관한 변경·삭제·리팩터가 아니며, 사용자 변경/기존 내용을 보존하는가?',
      '3) 구조화 파일(JSON/YAML/MD)은 구조를 존중해 필요한 부분만 편집하는가?',
      '4) 끝나면 돌릴 최소 검증을 정했는가?',
    ].join('\n');
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          additionalContext: checklist,
        },
      })
    );
  } catch (e) {
    // never break the tool call
  }
  process.exit(0);
});
