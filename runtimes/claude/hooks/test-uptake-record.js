#!/usr/bin/env node
// Fixture tests for uptake-record.js (spec: one row per tool-using session,
// located by transcript_path or by globbing session_id, counting the channels
// and the gate.* counters of the retired symbol-search-gate; silent, fail-open, no row for a
// session that used no tools).
// Run: node test-uptake-record.js  → exits non-zero on any failure.
const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOOK = path.join(__dirname, 'uptake-record.js');
const tdir = fs.mkdtempSync(path.join(os.tmpdir(), 'uptake-test-'));

function use(name, input, id) {
  return JSON.stringify({ message: { content: [{ type: 'tool_use', name, input, id: id || 'x' }] } });
}
function result(id, body, isErr) {
  return JSON.stringify({
    message: { content: [{ type: 'tool_result', tool_use_id: id, content: body, is_error: !!isErr }] },
  });
}
function transcript(lines) {
  const p = path.join(tdir, 'tr-' + Math.abs(lines.join('').length) + '-' + fs.readdirSync(tdir).length + '.jsonl');
  fs.writeFileSync(p, lines.join('\n') + '\n');
  return p;
}
function run(payload, outDir) {
  execSync('node ' + JSON.stringify(HOOK), {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    env: Object.assign({}, process.env, { OMA_UPTAKE_DIR: outDir }),
  });
  const f = path.join(outDir, 'rows.jsonl');
  if (!fs.existsSync(f)) return [];
  return fs.readFileSync(f, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
}
function fresh() {
  const d = fs.mkdtempSync(path.join(tdir, 'out-'));
  return d;
}

let failed = 0;
function check(name, cond, detail) {
  if (!cond) { failed++; console.log('FAIL  ' + name + (detail ? '  ' + detail : '')); }
  else console.log('PASS  ' + name);
}

// --- counts the channels ----------------------------------------------------
const tr1 = transcript([
  use('Bash', { command: 'rg "TODO" src/' }, 'a'),
  use('Bash', { command: 'graphify query "x"' }, 'b'),
  use('mcp__serena__find_symbol', { name_path_pattern: 'f' }, 'c'),
  use('Read', { file_path: '/x.py' }, 'd'),
  use('Read', { file_path: '/x.py' }, 'e'),
  use('Read', { file_path: '/y.py', offset: 1, limit: 5 }, 'f'),
]);
let rows = run({ session_id: 's1', cwd: '/p', reason: 'exit', transcript_path: tr1 }, fresh());
check('one row per session', rows.length === 1, 'got ' + rows.length);
const r = rows[0] || { nav: {}, reads: {} };
check('rg counted', r.nav.rg === 1, JSON.stringify(r.nav));
check('graphify counted', r.nav.graphify === 1);
check('serena counted', r.nav.serena === 1);
check('ranged vs full reads', r.reads.full === 2 && r.reads.ranged === 1, JSON.stringify(r.reads));
check('duplicate read counted', r.reads.dup === 1, JSON.stringify(r.reads));

// --- the three tools installed 2026-08-16 (ocr, semantica, karpathy) ---------
// Installed through the harness on the operator's call after the 2026-08-07
// survey rated them "manual delivery, 0-5% uptake expected". Whether that
// prediction holds is exactly what this ledger is for, so each gets a counter
// from the day it was installed. Negative fixtures for ocr: the binary is a
// 3-letter word and `cmd.indexOf('ocr')` would count `docr`, `ocrypt`, and a
// path containing it.
const tr5 = transcript([
  use('Bash', { command: 'ocr delegate preview' }, 'a'),
  use('Bash', { command: 'git status && ocr review --from main' }, 'b'),
  use('Bash', { command: 'ls docr/ ocrypt.py /tmp/ocr-notes.txt' }, 'c'),   // none of these
  use('mcp__semantica__record_decision', { category: 'x' }, 'd'),
  use('mcp__semantica__get_graph_summary', {}, 'e'),
  use('Skill', { skill: 'karpathy-guidelines' }, 'f'),
  use('Skill', { skill: 'spec-interview' }, 'g'),                            // not karpathy
  use('Skill', { skill: 'ponytail:ponytail-review' }, 'h'),
  use('Skill', { skill: 'ponytail' }, 'i'),
  use('Skill', { skill: 'ponytailor' }, 'j'),                                 // not ponytail
]);
rows = run({ session_id: 's5', cwd: '/p', reason: 'exit', transcript_path: tr5 }, fresh());
const r5 = rows[0] || { nav: {}, skills: {} };
check('ocr counted as a command, not a substring', r5.nav.ocr === 2, JSON.stringify(r5.nav));
check('semantica MCP calls counted', r5.nav.semantica === 2, JSON.stringify(r5.nav));
check('karpathy skill load counted, other skills not', r5.skills && r5.skills.karpathy === 1, JSON.stringify(r5.skills));
check('ponytail skills counted (scoped and bare), lookalike not', r5.skills && r5.skills.ponytail === 2, JSON.stringify(r5.skills));
// A row from a session that used none of them must still CARRY the keys with
// 0 — key-absent-vs-zero: absent means "scanner predates the counter", and
// the consumer renders only rows that carry the key.
check('new keys present at 0 on a session that used none', r.nav.ocr === 0 && r.nav.semantica === 0 && r.skills && r.skills.karpathy === 0,
      JSON.stringify({ nav: r.nav, skills: r.skills }));

// --- the gate.* counters (hook retired 2026-08-16; still scanned for old rows) --
const tr2 = transcript([
  use('Bash', { command: 'rg "def foo" lib/' }, 'g'),
  result('g', '[탐색 게이트] 이 검색은 `foo` 의 정의를 찾는 것으로 보입니다.', true),
  use('Bash', { command: 'rg "def foo" lib/  # 텍스트검색: 근거' }, 'h'),
]);
rows = run({ session_id: 's2', cwd: '/p', reason: 'exit', transcript_path: tr2 }, fresh());
check('gate denial counted', (rows[0] || {}).gate && rows[0].gate.denied === 1, JSON.stringify((rows[0] || {}).gate));
check('gate escape counted', (rows[0] || {}).gate && rows[0].gate.escape === 1);
// A denial count alone cannot tell a working gate from one that is routed
// around: of the 28 firings on this machine, 21% reached serena and 54% re-ran
// the same search with the escape appended. The outcome is the deciding number.
check('denial resolved by the escape is recorded as such',
      rows[0].gate.to_escape === 1 && rows[0].gate.to_serena === 0, JSON.stringify(rows[0].gate));

const tr2b = transcript([
  use('Bash', { command: 'rg "def foo" lib/' }, 'g2'),
  result('g2', '[탐색 게이트] 정의 조회로 보입니다.', true),
  use('ToolSearch', { query: 'select:mcp__serena__find_symbol' }, 'g3'),
  use('mcp__serena__find_symbol', { name_path_pattern: 'foo' }, 'g4'),
]);
rows = run({ session_id: 's2b', cwd: '/p', reason: 'exit', transcript_path: tr2b }, fresh());
// ToolSearch is how a deferred symbol tool gets loaded. Scoring it as "did
// something else" would mark the gate's one success path as a failure.
check('a denial that reaches serena through ToolSearch counts as success',
      rows[0].gate.to_serena === 1 && rows[0].gate.to_other === 0, JSON.stringify(rows[0].gate));

const tr2c = transcript([
  use('Bash', { command: 'rg "def foo" lib/' }, 'h1'),
  result('h1', '[탐색 게이트] 정의 조회로 보입니다.', true),
  use('Read', { file_path: '/lib/foo.py' }, 'h2'),
]);
rows = run({ session_id: 's2c', cwd: '/p', reason: 'exit', transcript_path: tr2c }, fresh());
check('a denial answered by reading the file is its own outcome',
      rows[0].gate.to_read === 1, JSON.stringify(rows[0].gate));

const tr2d = transcript([
  use('mcp__serena__find_symbol', { name_path_pattern: 'x' }, 'i1'),
  result('i1', 'ValueError: while the path is ignored', true),
]);
rows = run({ session_id: 's2d', cwd: '/p', reason: 'exit', transcript_path: tr2d }, fresh());
// A serena call that errors is not a serena call that worked. Counting only
// invocations is how "symbol tools are being used" survived 13 configs the
// release could not load at all.
check('a failed serena call is counted separately',
      rows[0].nav.serena === 1 && rows[0].nav.serena_err === 1, JSON.stringify(rows[0].nav));

// --- failures ---------------------------------------------------------------
const tr3 = transcript([
  use('Bash', { command: 'false' }, 'i'), result('i', 'boom', true),
  use('Edit', { file_path: '/z' }, 'j'), result('j', 'nope', true),
]);
rows = run({ session_id: 's3', cwd: '/p', reason: 'exit', transcript_path: tr3 }, fresh());
check('bash and edit failures split', rows[0].fail.bash === 1 && rows[0].fail.edit === 1, JSON.stringify(rows[0].fail));

// --- a session with no tool use must not dilute the rates -------------------
const tr4 = transcript([JSON.stringify({ message: { content: [{ type: 'text', text: 'hi' }] } })]);
rows = run({ session_id: 's4', cwd: '/p', reason: 'exit', transcript_path: tr4 }, fresh());
check('no row for a tool-free session', rows.length === 0, 'got ' + rows.length);

// --- located by session id when transcript_path is absent -------------------
const projects = path.join(tdir, 'projects', '-p');
fs.mkdirSync(projects, { recursive: true });
fs.copyFileSync(tr1, path.join(projects, 's5.jsonl'));
const out5 = fresh();
execSync('node ' + JSON.stringify(HOOK), {
  input: JSON.stringify({ session_id: 's5', cwd: '/p', reason: 'exit' }),
  encoding: 'utf8',
  env: Object.assign({}, process.env, {
    OMA_UPTAKE_DIR: out5, OMA_PROJECTS_DIR: path.join(tdir, 'projects'),
  }),
});
check('found by session-id glob', fs.existsSync(path.join(out5, 'rows.jsonl')));

// --- rows accumulate, they do not overwrite ---------------------------------
const shared = fresh();
run({ session_id: 's6', cwd: '/p', reason: 'exit', transcript_path: tr1 }, shared);
rows = run({ session_id: 's7', cwd: '/p', reason: 'exit', transcript_path: tr2 }, shared);
check('rows append', rows.length === 2, 'got ' + rows.length);

// --- fail-open --------------------------------------------------------------
let threw = false;
try {
  execSync('node ' + JSON.stringify(HOOK), {
    input: 'not json', encoding: 'utf8',
    env: Object.assign({}, process.env, { OMA_UPTAKE_DIR: fresh() }),
  });
} catch (e) { threw = true; }
check('malformed stdin does not fail the hook', !threw);

let out = '';
try {
  out = execSync('node ' + JSON.stringify(HOOK), {
    input: JSON.stringify({ session_id: 'missing', cwd: '/p' }), encoding: 'utf8',
    env: Object.assign({}, process.env, { OMA_UPTAKE_DIR: fresh(), OMA_PROJECTS_DIR: tdir }),
  });
} catch (e) { out = 'THREW'; }
check('absent transcript is silent, not fatal', out === '');

fs.rmSync(tdir, { recursive: true, force: true });
console.log(failed ? 'uptake-record: ' + failed + ' failure(s)' : 'uptake-record: OK');
process.exit(failed ? 1 : 0);
