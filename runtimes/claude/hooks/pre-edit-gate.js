#!/usr/bin/env node
// PreToolUse(Edit|Write|MultiEdit|NotebookEdit) hook. Denies direct writes
// inside .agents and guards new-content size using only tool input paths and
// content. Warn > 300 lines or 30KB; deny > 800 lines or 80KB (UTF-8).
const fs = require('fs');
const path = require('path');

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

// Resolve existing parent components so symlinked destinations are checked
// against their canonical path. A non-existent destination is normalized from
// its nearest existing parent.
function canonicalPath(filePath) {
  if (typeof filePath !== 'string' || filePath === '') return '';
  let candidate = path.resolve(filePath);
  const suffix = [];
  while (true) {
    try {
      return path.join(fs.realpathSync.native(candidate), ...suffix.reverse());
    } catch (e) {
      const parent = path.dirname(candidate);
      if (parent === candidate) return path.resolve(filePath);
      suffix.push(path.basename(candidate));
      candidate = parent;
    }
  }
}

function isAgentsPath(filePath, cwd) {
  const base = typeof cwd === 'string' && cwd ? cwd : process.cwd();
  const lexical = path.resolve(base, filePath || '');
  const canonical = canonicalPath(lexical);
  return lexical.split(path.sep).includes('.agents')
    || canonical.split(path.sep).includes('.agents');
}

function out(obj) {
  process.stdout.write(JSON.stringify(obj));
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
    if (isAgentsPath(fp, payload.cwd)) {
      return out({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason:
            '[편집 대상 게이트] .agents 내부 파일은 Edit, Write, MultiEdit 또는 NotebookEdit으로 직접 변경할 수 없습니다.',
        },
      });
    }
    const exempt = ALLOW_PATH.some((re) => re.test(fp));

    if (!exempt && (lines > DENY_LINES || bytes > DENY_BYTES)) {
      const reason =
        '[분량 게이트] 이 ' + toolName + ' 호출의 신규 내용이 ' +
        lines + '줄/' + Math.round(bytes / 1024) + 'KB로 차단 기준(' +
        DENY_LINES + '줄 또는 ' + Math.round(DENY_BYTES / 1024) + 'KB)을 초과했습니다. ' +
        '파일·기능 단위로 분해해 ' + WARN_LINES + '줄 이하 단위로 나눠 작성하고, ' +
        '각 단계마다 최소 검증을 거치세요.';
      out({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: reason,
        },
      });
    }
    if (!exempt && (lines > WARN_LINES || bytes > WARN_BYTES)) {
      return out({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          additionalContext:
            '[분량 경고] 신규 내용 ' + lines + '줄/' + Math.round(bytes / 1024) +
            'KB — 권장 기준(' + WARN_LINES + '줄/' + Math.round(WARN_BYTES / 1024) +
            'KB)을 초과했습니다. 다음 편집부터는 더 작은 단위로 분할을 권장합니다.',
        },
      });
    }
    return process.exit(0);
  } catch (e) {
    // fail-open: never break the tool call on gate errors
  }
  process.exit(0);
});
