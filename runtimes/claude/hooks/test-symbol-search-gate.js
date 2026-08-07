#!/usr/bin/env node
// Fixture tests for symbol-search-gate.js (spec: deny a DEFINITION lookup typed
// as rg/grep in a serena-activated project, name find_symbol as the
// replacement; escape via "텍스트검색:" in the command or the current-turn user
// prompt; fail-open).
// Run: node test-symbol-search-gate.js  → exits non-zero on any failure.
//
// Both false positives below were found by running the hook for real, not by
// reading it. The first version scanned every quoted string in the command and
// blocked a python heredoc that merely contained the text "def load_min"; and
// it had no self-escape, so when serena legitimately could not answer (a python
// function inside a shell file, in a project registered as `languages: [bash]`)
// there was no way forward at all. Both cases are pinned here.
const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOOK = path.join(__dirname, 'symbol-search-gate.js');

const tdir = fs.mkdtempSync(path.join(os.tmpdir(), 'ssg-test-'));
const serenaProj = path.join(tdir, 'proj');
fs.mkdirSync(path.join(serenaProj, '.serena'), { recursive: true });
fs.writeFileSync(path.join(serenaProj, '.serena', 'project.yml'), 'languages:\n- python\n');
const plainProj = path.join(tdir, 'plain');
fs.mkdirSync(plainProj, { recursive: true });

// A transcript whose last user prompt carries the escape marker.
const transcript = path.join(tdir, 't.jsonl');
fs.writeFileSync(
  transcript,
  JSON.stringify({ type: 'user', message: { role: 'user', content: '텍스트검색: 주석을 찾는다' } }) + '\n'
);

function run(payload) {
  const stdin = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const stdout = execSync('node ' + JSON.stringify(HOOK), { input: stdin, encoding: 'utf8' });
  return stdout ? JSON.parse(stdout) : null;
}
function verdict(res) {
  const h = (res || {}).hookSpecificOutput || {};
  if (h.permissionDecision === 'deny') return 'deny';
  if (res === null) return 'pass';
  return 'unknown';
}

let failed = 0;
function check(name, cmd, cwd, expected, extra) {
  let got;
  try {
    got = verdict(run(Object.assign({ tool_name: 'Bash', tool_input: { command: cmd }, cwd }, extra || {})));
  } catch (e) {
    got = 'error:' + e.message;
  }
  const ok = got === expected;
  if (!ok) failed++;
  console.log((ok ? 'PASS' : 'FAIL') + '  ' + name + '  expected=' + expected + ' got=' + got);
}

// --- the thing it exists to catch -------------------------------------------
check('def lookup is denied', 'rg "def load_min" lib/', serenaProj, 'deny');
check('class lookup is denied', "rg 'class Foo' src/", serenaProj, 'deny');
check('flags before the pattern are skipped', 'rg -n "def parse" .', serenaProj, 'deny');
check('-e PATTERN form', 'rg -e "def parse" .', serenaProj, 'deny');

// --- false positive #1: not a search at all ---------------------------------
// This exact shape is what the first version blocked in real use: a diagnostic
// that greps one thing and then runs a python heredoc which merely CONTAINS the
// text "def load_min". Scanning the whole command found it; scanning the search
// pattern does not. Without the grep in front the command never reaches the
// pattern check at all, so a heredoc-only fixture proves nothing — that gap is
// why the whole-command mutation survived the first round.
check(
  'grep plus a python heredoc that mentions a def',
  'grep -A2 "^languages:" .serena/project.yml\npython3 - <<PY\nfor l in open("x"):\n    if "def load_min" in l: print(l)\nPY',
  serenaProj,
  'pass'
);
check(
  'python heredoc alone',
  'python3 - <<PY\nfor l in open("x"):\n    if "def load_min" in l: print(l)\nPY',
  serenaProj,
  'pass'
);
check('a path that contains the word', 'ls lib/def_helpers.py', serenaProj, 'pass');
check('glob flag value is not the pattern', 'rg -g "*.py" "TODO" .', serenaProj, 'pass');
// A glob shaped like a definition is still a glob, not the search term.
check('glob that looks like a definition', 'rg -g "class Foo*" "TODO" .', serenaProj, 'pass');

// --- ordinary searches must be untouched ------------------------------------
check('plain word search', 'rg "TODO" docs/', serenaProj, 'pass');
check('file listing', 'rg --files', serenaProj, 'pass');
check('bare keyword with no identifier', 'rg "function" README.md', serenaProj, 'pass');

// --- scope ------------------------------------------------------------------
check('non-serena project is untouched', 'rg "def load_min" lib/', plainProj, 'pass');

// --- false positive #2: the escape must be reachable without the user -------
check(
  'self-escape in the command',
  'rg "def load_min" lib/  # 텍스트검색: heredoc 내부라 serena 미인덱싱',
  serenaProj,
  'pass'
);
check('user-prompt escape', 'rg "def load_min" lib/', serenaProj, 'pass', {
  transcript_path: transcript,
});

// --- fail-open --------------------------------------------------------------
check('malformed stdin', 'not json', serenaProj, 'pass');

// The denial is only useful if it names the replacement.
try {
  const res = run({ tool_name: 'Bash', tool_input: { command: 'rg "def load_min" lib/' }, cwd: serenaProj });
  const reason = ((res || {}).hookSpecificOutput || {}).permissionDecisionReason || '';
  const named = reason.includes('mcp__serena__find_symbol') && reason.includes('load_min');
  if (!named) failed++;
  console.log((named ? 'PASS' : 'FAIL') + '  denial names find_symbol and the symbol');
} catch (e) {
  failed++;
  console.log('FAIL  denial names find_symbol and the symbol  error=' + e.message);
}

fs.rmSync(tdir, { recursive: true, force: true });
console.log(failed ? 'symbol-search-gate: ' + failed + ' failure(s)' : 'symbol-search-gate: OK');
process.exit(failed ? 1 : 0);
