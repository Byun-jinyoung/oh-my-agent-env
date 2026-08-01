#!/usr/bin/env node
// PreToolUse(Bash) hook: size guard for the bypass route where a large file
// payload is inlined into the command string (heredoc / tee / echo-redirect).
// Measures tool_input.command size only — no shell parsing, so no
// pattern-guessing false positives. Cross-reviewed spec, aligned with
// pre-edit-gate.js: warn > 300 lines or 30KiB, deny > 800 lines or 80KiB
// (UTF-8); escape via current-turn user prompt "대용량허용:"; fail-open.
// Below warn threshold: completely silent (no stdout) — this hook must not
// add noise to every Bash call, and stays a pure decision (no side effects).
const fs = require('fs');

const WARN_LINES = 300;
const DENY_LINES = 800;
const WARN_BYTES = 30 * 1024;
const DENY_BYTES = 80 * 1024;
const USER_MARKER = /대용량허용:/;

// Same logic as pre-edit-gate.js — duplicated because hook scripts must be
// self-contained (require()-ing a sibling hook would execute its stdin loop).
function userAllowedLargeWrite(transcriptPath) {
  if (!transcriptPath || !fs.existsSync(transcriptPath)) return false;
  let lastPromptText = '';
  for (const l of fs.readFileSync(transcriptPath, 'utf8').split('\n')) {
    if (!l) continue;
    let d;
    try { d = JSON.parse(l); } catch (e) { continue; }
    if (d.type !== 'user') continue;
    const m = d.message || {};
    if (m.role !== 'user') continue;
    const c = m.content;
    if (typeof c === 'string' && c.trim() !== '') lastPromptText = c;
    else if (Array.isArray(c)) {
      const texts = c.filter((it) => it && it.type === 'text').map((it) => it.text || '');
      if (texts.length) lastPromptText = texts.join('\n');
    }
  }
  return USER_MARKER.test(lastPromptText);
}

const stdinTimeout = setTimeout(() => process.exit(0), 5000);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (input += c));
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const payload = JSON.parse(input || '{}');
    const cmd = (payload.tool_input || {}).command;
    if (typeof cmd !== 'string') return process.exit(0);
    const lines = cmd.split('\n').length;
    const bytes = Buffer.byteLength(cmd, 'utf8');

    if (lines > DENY_LINES || bytes > DENY_BYTES) {
      if (userAllowedLargeWrite(payload.transcript_path)) return process.exit(0);
      process.stdout.write(
        JSON.stringify({
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            permissionDecision: 'deny',
            permissionDecisionReason:
              '[분량 게이트] 이 Bash 명령이 ' + lines + '줄/' + Math.round(bytes / 1024) +
              'KB로 차단 기준(' + DENY_LINES + '줄 또는 ' + Math.round(DENY_BYTES / 1024) +
              'KB)을 초과했습니다. 대용량 내용을 명령 문자열에 인라인(heredoc/tee/echo)하지 말고, ' +
              'Write/Edit 도구로 ' + WARN_LINES + '줄 이하 단위로 분할해 작성하세요. ' +
              '정당한 대용량 작업이면 사용자가 프롬프트에 "대용량허용: <경로> <이유>"를 명시해야 통과됩니다.',
          },
        })
      );
      return process.exit(0);
    }
    if (lines > WARN_LINES || bytes > WARN_BYTES) {
      process.stdout.write(
        JSON.stringify({
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            additionalContext:
              '[분량 경고] 이 Bash 명령은 ' + lines + '줄/' + Math.round(bytes / 1024) +
              'KB입니다. 대용량 내용 인라인은 실수 위험이 큽니다 — 파일 생성은 Write/Edit로 분할 작성을 권장합니다.',
          },
        })
      );
    }
  } catch (e) {
    // fail-open: never break the tool call on guard errors
  }
  process.exit(0);
});
