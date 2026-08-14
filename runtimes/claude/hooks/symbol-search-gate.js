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
//   - it must be a lookup of ONE symbol and nothing else (see isSingleSymbol)
//   - it must sit inside a quoted argument, not anywhere in the command line
//   - the project must be serena-activated (.serena/project.yml)
// A bare word search, a log grep, `rg --files`: all untouched.
// Escape via current-turn user prompt "텍스트검색:". Fail-open everywhere.
//
// The one-symbol rule was added after replaying every firing this hook would
// produce across ~/.claude/projects. Of 337, only 146 (43.3%) were a lookup of
// a single symbol. The other 56.7% were shapes serena cannot answer at all:
//
//   175  alternation      `def torsion_action_kinematics|def a2_metric_basis`
//     8  prefix sweep     `^def test_`
//     7  regex meta       `^-.*(def _red_|BOLTZ_RED_|tail_kill|TAIL)`
//
// Denying those achieves nothing: serena returns [] for every one, so the model
// re-runs the same search with the escape appended. That is not a hypothesis —
// the escape was used in 54% of the 28 recorded firings, which is the same
// number as the 56.7% this rule now lets through. Blocking a search that the
// named replacement cannot serve is pure friction, and it is the friction that
// teaches the model to reach for the escape by reflex.
//
// Replaying this file over the 557 candidate commands in the corpus: 337
// firings before the rule, 123 after.
//
// Two misfire classes are KNOWN TO REMAIN, both inside those 123. Neither is
// fixable here, and pretending otherwise is worse than naming them:
//
//   - the path is inside the project but serena ignores it (gitignored build/,
//     vendored trees, .venv). serena answers "ValueError: ... while the path is
//     ignored" — the very error that opened this investigation. Knowing this at
//     PreToolUse time would mean reading serena's own ignore config from a hook
//     that must stay fast and fail-open.
//   - the pattern is one symbol but a ubiquitous one. `def __init__` is a clean
//     single-symbol lookup whose find_symbol answer measured 40,381 bytes
//     (`forward` 13,621). Which names explode is not knowable without asking,
//     and asking is the thing a PreToolUse hook cannot do.
//
// So 123 is the count of firings, not the count of useful firings.
const fs = require('fs');
const path = require('path');

const USER_MARKER = /텍스트검색:/;
// The keyword set is intentionally short: these are the ones whose presence
// makes "I am looking for where this is defined" unambiguous.
const DEF = /\b(?:def|class|function|func|fn|struct|interface|impl)\s+([A-Za-z_][A-Za-z0-9_]*)/;
const SEARCH_CMD = /(?:^|[|&;(]|\s)(?:rg|grep|egrep|ack|ag)\s/;
// True only when the pattern is `def foo` and nothing else — anchors allowed,
// since `^def foo` is still one symbol. Anything else left over (a paren, a
// character class, an alternation, a second word) means the search is not the
// question find_symbol answers, so the gate must stay out of the way.
//
// `hit` is the DEF match, so removing hit[0] removes the keyword AND the name
// in one step; whatever survives is by definition not part of the lookup.
//
// There was an explicit alternation test here first. It was dead: an
// alternation cannot exist without leaving a token outside the `def foo` match,
// so this check already catches every one. Checked against the corpus rather
// than argued — of the patterns this hook would fire on, the number carrying an
// alternation AND no leftover token is 0, and a mutation removing the
// alternation test killed no test.
//
// Strict on purpose. `class Foo\b` is a single-symbol lookup that this rejects,
// because the asymmetry runs one way: a gate that stays quiet costs nothing,
// while a gate that fires on a search serena cannot answer costs a denial, a
// re-run and an escape — and teaches the escape as a reflex.
function isSingleSymbol(pattern, hit) {
  // No .trim() here: it was written, no test needed it, and dropping it only
  // makes the rule stricter (a stray space keeps the gate quiet), which is the
  // side this hook should err on.
  const rest = (pattern.slice(0, hit.index) + pattern.slice(hit.index + hit[0].length))
    .replace(/^\^+/, '')
    .replace(/\$+$/, '');
  if (rest !== '') return false;
  // A trailing underscore rejects two different things at once, which is why
  // there is one rule here and not two:
  //   - prefix sweeps, how every one in the corpus was written (`^def test_`,
  //     `^def _red_`). serena has no prefix mode reachable from a name, so
  //     these are denials with no destination.
  //   - dunders. `def __init__` is a single symbol by shape and a catastrophe
  //     by answer, because every class in the tree defines one: find_symbol
  //     measured 40,381 bytes against the ~20KB cap rg's output would have hit.
  //     A separate /^__.*__$/ rule was written for this and every mutation of
  //     it survived — this line already covered it.
  // It does NOT reject a leading underscore: `def _validate_shapes` is a normal
  // private definition and serena answers it in 195 bytes.
  return !hit[1].endsWith('_');
}

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
    if (!isSingleSymbol(pattern, hit)) return process.exit(0);
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
