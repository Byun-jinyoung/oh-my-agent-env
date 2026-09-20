#!/usr/bin/env node
// PreToolUse(Read) hook: staged size gate against whole-file reads.
// Measured basis: 32% of Read calls in recent substantial sessions were
// unbounded (no limit/offset); a 100KB file read whole is ~25k tokens.
// Staged rollout (cross-reviewed): 20-50KB warn, 50-100KB strong warn,
// >100KB deny. Lower the deny line to 50KB after a false-positive
// observation period. Reads WITH limit/offset/pages always pass.
// No transcript-text escape: bounded reads are the deterministic alternative.
// Fail-open on parser or filesystem errors.
const fs = require('fs');

const WARN_BYTES = 20 * 1024;
const STRONG_BYTES = 50 * 1024;
const DENY_BYTES = 100 * 1024;
function ctx(text) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: text },
    })
  );
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
    const inp = payload.tool_input || {};
    if (inp.limit !== undefined || inp.offset !== undefined || inp.pages !== undefined)
      return process.exit(0); // bounded read — always fine
    const fp = inp.file_path;
    if (!fp || !fs.existsSync(fp)) return process.exit(0);
    const size = fs.statSync(fp).size;
    const kb = Math.round(size / 1024);

    if (size > DENY_BYTES) {
      process.stdout.write(
        JSON.stringify({
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            permissionDecision: 'deny',
            permissionDecisionReason:
              '[분량 게이트] 이 파일은 ' + kb + 'KB로 전체 Read 차단 기준(' +
              Math.round(DENY_BYTES / 1024) + 'KB)을 초과합니다. offset/limit로 필요한 구간만 읽거나, ' +
              '분석 목적이면 ctx_execute_file로 샌드박스에서 처리해 답만 가져오세요. ' +
              'Edit 목적이면 대상 구간 주변만 offset/limit로 읽으면 충분합니다.',
          },
        })
      );
      return process.exit(0);
    }
    if (size > STRONG_BYTES)
      return ctx(
        '[분량 경고·강] 이 파일은 ' + kb + 'KB입니다. 전체 Read는 컨텍스트를 크게 소모합니다 — ' +
          'offset/limit 분할 읽기 또는 ctx_execute_file(샌드박스 분석)을 사용하세요. ' +
          '100KB 초과 파일은 차단됩니다.'
      );
    if (size > WARN_BYTES)
      return ctx('[분량 경고] 이 파일은 ' + kb + 'KB입니다. 필요한 구간만 offset/limit로 읽는 것을 권장합니다.');
  } catch (e) {
    // fail-open: never break the tool call on gate errors
  }
  process.exit(0);
});
