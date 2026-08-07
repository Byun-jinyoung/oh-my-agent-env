#!/usr/bin/env node
// Fixture tests for uptake-record.js (spec: one row per tool-using session,
// located by transcript_path or by globbing session_id, counting the channels
// and the two symbol-search-gate counters; silent, fail-open, no row for a
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

// --- the two counters that answer whether symbol-search-gate works ----------
const tr2 = transcript([
  use('Bash', { command: 'rg "def foo" lib/' }, 'g'),
  result('g', '[탐색 게이트] 이 검색은 `foo` 의 정의를 찾는 것으로 보입니다.', true),
  use('Bash', { command: 'rg "def foo" lib/  # 텍스트검색: 근거' }, 'h'),
]);
rows = run({ session_id: 's2', cwd: '/p', reason: 'exit', transcript_path: tr2 }, fresh());
check('gate denial counted', (rows[0] || {}).gate && rows[0].gate.denied === 1, JSON.stringify((rows[0] || {}).gate));
check('gate escape counted', (rows[0] || {}).gate && rows[0].gate.escape === 1);

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
