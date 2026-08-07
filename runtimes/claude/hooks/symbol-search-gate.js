#!/usr/bin/env node
// PreToolUse(Bash) hook: a definition lookup typed as rg/grep is answered by
// serena, not by scanning text.
//
// Why, measured over 220 tool-using sessions in ~/.claude/projects:
//
//   Bash + rg/grep     129 sessions  58.6%   5291 calls
//   Read               154 sessions  70.0%   3046 calls
//   serena               2 sessions   0.9%      3 calls
//   lsp_* / ast_grep     0 sessions   0.0%      0 calls
//
// Even in the Python repo where a symbol tool helps most, serena appears in 1
// of 64 sessions. The tools are installed, the project CLAUDE.md prescribes
// them, and a SessionStart primer repeats it every single session. None of
// that moves the number: every prose-only channel in this harness sits between
// 0% and 5%, while context-mode — the one with a hook behind it — sits at 44%.
// The cost at the decision point decides it. `rg` is one call and already
// loaded; serena is ToolSearch plus a call, in an output shape used less often.
//
// So this hook does not hint. A hint is what the graphify hook does, and that
// hook was additionally dead for its whole life without anyone noticing. This
// denies the call and names the exact replacement — the shape bash-size-guard.js
// already uses here.
//
// Deliberately narrow, because rg is the most-used tool in the corpus and a
// false positive on 5291 calls would get the whole thing switched off:
//   - the pattern must be a DEFINITION (`def foo`, `class Bar`, ...)
//   - it must sit inside a quoted argument, not anywhere in the command line
//   - the project must be serena-activated (.serena/project.yml)
// A bare word search, a log grep, `rg --files`: all untouched.
// Escape via current-turn user prompt "텍스트검색:". Fail-open everywhere.
const fs = require('fs');
const path = require('path');

const USER_MARKER = /텍스트검색:/;
// The keyword set is intentionally short: these are the ones whose presence
// makes "I am looking for where this is defined" unambiguous.
const DEF = /\b(?:def|class|function|func|fn|struct|interface|impl)\s+([A-Za-z_][A-Za-z0-9_]*)/;
const SEARCH_CMD = /(?:^|[|&;(]|\s)(?:rg|grep|egrep|ack|ag)\s/;

// Same scan as bash-size-guard.js — duplicated on purpose: requiring a sibling
// hook would run its stdin loop.
function userAllowedTextSearch(transcriptPath) {
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

// Only the SEARCH PATTERN — the first non-flag argument after the rg/grep
// token. Scanning every quoted string in the command was the first version and
// it was wrong twice over on the first real call: it fired on a python heredoc
// that merely contained the text "def load_min", blocking a diagnostic that was
// not a search at all. The pattern argument is the only thing that says what is
// being looked for.
function searchPattern(cmd) {
  const m = /(?:^|[|&;(]|\s)(?:rg|grep|egrep|ack|ag)\s+([\s\S]*)$/.exec(cmd);
  if (!m) return null;
  const rest = m[1];
  const tok = /'([^']*)'|"([^"]*)"|(\S+)/g;
  let t;
  while ((t = tok.exec(rest)) !== null) {
    const quoted = t[1] !== undefined ? t[1] : t[2];
    const bare = t[3];
    if (quoted !== undefined) return quoted;      // first quoted arg wins
    if (bare === undefined) continue;
    if (bare === '--') continue;
    if (bare.startsWith('-')) {                   // a flag
      // -g/--glob takes a value that is NOT the pattern; without stepping over
      // it, a glob shaped like a definition (`-g "class Foo*"`) would be read
      // as the search term. -e/--regexp needs no special case: its value is the
      // pattern, and the loop returns the next argument anyway. That branch was
      // written, survived every mutation, and is gone for exactly that reason.
      if (/^-g$|^--glob$|^--iglob$/.test(bare)) tok.lastIndex = skipOne(rest, tok.lastIndex);
      continue;
    }
    return bare;                                  // first bare non-flag arg
  }
  return null;
}
function skipOne(rest, from) {
  const tok = /'([^']*)'|"([^"]*)"|(\S+)/g;
  tok.lastIndex = from;
  const t = tok.exec(rest);
  return t ? tok.lastIndex : from;
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
    if (typeof cmd !== 'string' || !SEARCH_CMD.test(cmd)) return process.exit(0);

    const cwd = payload.cwd || process.cwd();
    if (!fs.existsSync(path.join(cwd, '.serena', 'project.yml'))) return process.exit(0);

    // Self-escape. The user-prompt escape alone was wrong: the case that needs
    // an escape is "serena cannot answer this one", and that is discovered by
    // whoever ran the search, not by the user. First real call proved it —
    // serena returned [] for a python function living inside a shell heredoc,
    // a shape its bash backend does not index, and there was no way forward.
    if (USER_MARKER.test(cmd)) return process.exit(0);

    const pattern = searchPattern(cmd);
    if (pattern === null) return process.exit(0);
    const hit = DEF.exec(pattern);
    if (!hit) return process.exit(0);
    const symbol = hit[1];
    if (userAllowedTextSearch(payload.transcript_path)) return process.exit(0);

    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason:
            '[탐색 게이트] 이 검색은 `' + symbol + '` 의 정의를 찾는 것으로 보입니다. ' +
            '이 프로젝트는 serena 활성 상태이므로 mcp__serena__find_symbol 로 ' +
            '정의·시그니처·본문을 한 번에 받으십시오 (참조는 find_referencing_symbols). ' +
            '도구가 아직 로드되지 않았다면 ToolSearch("select:mcp__serena__find_symbol") 먼저. ' +
            'serena가 답하지 못하거나(예: 인덱싱되지 않는 언어·heredoc 내부) 주석·문서·' +
            '문자열 리터럴을 찾는 것이라면, 명령 끝에 `# 텍스트검색: <이유>` 를 붙여 다시 실행하십시오. ' +
            '사용자 프롬프트의 "텍스트검색:" 도 동일하게 통과시킵니다.',
        },
      })
    );
    return process.exit(0);
  } catch (e) {
    return process.exit(0);
  }
});
