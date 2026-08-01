#!/usr/bin/env node
// PreToolUse(Edit|Write|MultiEdit|NotebookEdit) hook — two jobs:
//
// 1) Checklist reminder (non-blocking, unchanged): surface the edit-time
//    checklist at the exact moment of file modification. Process-attitude
//    rules (ToDo exists, scope) stay reminder-only — no machine-observable
//    signal for them, a hard gate would false-block.
//
// 2) Size gate (machine-observable, cross-reviewed + user-confirmed spec):
//    lines/bytes of NEW content per tool call — warn > 300 lines or 30KB,
//    deny > 800 lines or 80KB (UTF-8). Escapes: path allowlist
//    (lock/min/generated/vendor) or current-turn user prompt containing
//    "대용량허용:". Fail-open on any parse/read error; deny only when
//    parsing succeeded and the threshold is genuinely exceeded.
const fs = require('fs');

const WARN_LINES = 300;
const DENY_LINES = 800;
const WARN_BYTES = 30 * 1024;
const DENY_BYTES = 80 * 1024;
const ALLOW_PATH = [
  /\.lock$/i,
  /\.min\./i,
  /(^|\/)generated\//,
  /(^|\/)__generated__\//,
  /\.generated\./,
  /(^|\/)vendor\//,
];
const USER_MARKER = /대용량허용:/;

const CHECKLIST = [
  '편집 전 체크 (반복작업 방지):',
  '1) 이 파일을 Read/이해했고, 바꾸기 전 기존 동작을 관찰했는가?',
  '2) 이 편집이 요청 범위 안인가? 무관한 변경·삭제·리팩터가 아니며, 사용자 변경/기존 내용을 보존하는가?',
  '3) 구조화 파일(JSON/YAML/MD)은 구조를 존중해 필요한 부분만 편집하는가?',
  '4) 끝나면 돌릴 최소 검증을 정했는가?',
].join('\n');

// New-content chunks per tool. Sum covers both aggregate and single-max
// (sum >= max, so one comparison suffices).
function newContentChunks(toolName, input) {
  if (toolName === 'Write') return [input.content];
  if (toolName === 'Edit') return [input.new_string];
  if (toolName === 'MultiEdit')
    return (input.edits || []).map((e) => e && e.new_string);
  if (toolName === 'NotebookEdit') return [input.new_source];
  return [];
}

function editedPath(input) {
  return input.file_path || input.notebook_path || '';
}

// Current-turn user escape: last genuine user prompt contains the marker.
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

function out(obj) {
  process.stdout.write(JSON.stringify(obj));
  process.exit(0);
}
function allowWithContext(context) {
  out({
    hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: context },
  });
}

const stdinTimeout = setTimeout(() => process.exit(0), 5000);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (input += c));
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const payload = JSON.parse(input || '{}');
    const toolName = payload.tool_name || '';
    const toolInput = payload.tool_input || {};
    const chunks = newContentChunks(toolName, toolInput).filter(
      (s) => typeof s === 'string'
    );
    let lines = 0;
    let bytes = 0;
    for (const s of chunks) {
      lines += s.split('\n').length;
      bytes += Buffer.byteLength(s, 'utf8');
    }
    const fp = editedPath(toolInput);
    const exempt = ALLOW_PATH.some((re) => re.test(fp));

    if (!exempt && (lines > DENY_LINES || bytes > DENY_BYTES)) {
      if (userAllowedLargeWrite(payload.transcript_path)) {
        // user explicitly allowed this large write — no deny, no split nag
        return allowWithContext(CHECKLIST);
      }
      {
        const reason =
          '[분량 게이트] 이 ' + toolName + ' 호출의 신규 내용이 ' +
          lines + '줄/' + Math.round(bytes / 1024) + 'KB로 차단 기준(' +
          DENY_LINES + '줄 또는 ' + Math.round(DENY_BYTES / 1024) + 'KB)을 초과했습니다. ' +
          '규칙 7: 파일·기능 단위로 분해해 ' + WARN_LINES + '줄 이하 단위로 나눠 작성하고, ' +
          '각 단계마다 최소 검증을 거치세요. 정당한 대용량 단일 파일이면 사용자가 프롬프트에 ' +
          '"대용량허용: <경로> <이유>"를 명시해야 통과됩니다.';
        out({
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            permissionDecision: 'deny',
            permissionDecisionReason: reason,
          },
        });
      }
    }
    if (!exempt && (lines > WARN_LINES || bytes > WARN_BYTES)) {
      return allowWithContext(
        CHECKLIST +
          '\n\n[분량 경고] 신규 내용 ' + lines + '줄/' + Math.round(bytes / 1024) +
          'KB — 권장 기준(' + WARN_LINES + '줄/' + Math.round(WARN_BYTES / 1024) +
          'KB)을 초과했습니다. 다음 편집부터는 더 작은 단위로 분할을 권장합니다.'
      );
    }
    return allowWithContext(CHECKLIST);
  } catch (e) {
    // fail-open: never break the tool call on gate errors
  }
  allowWithContext(CHECKLIST);
});
