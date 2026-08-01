#!/usr/bin/env node
// Fixture tests for pre-edit-gate.js size gate (spec: warn 300L/30KB, deny
// 800L/80KB, allowlist + user-prompt marker escape, fail-open).
// Run: node test-pre-edit-gate.js  → exits non-zero on any failure.
const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOOK = path.join(__dirname, 'pre-edit-gate.js');
const genLines = (n) => Array.from({ length: n }, (_, i) => 'line ' + i).join('\n');

function run(payload) {
  const stdin = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const stdout = execSync('node ' + JSON.stringify(HOOK), { input: stdin, encoding: 'utf8' });
  return stdout ? JSON.parse(stdout) : null;
}
function verdict(res) {
  const h = (res || {}).hookSpecificOutput || {};
  if (h.permissionDecision === 'deny') return 'deny';
  if ((h.additionalContext || '').includes('[분량 경고]')) return 'warn';
  if ((h.additionalContext || '').includes('편집 전 체크')) return 'allow';
  return 'unknown';
}

let failed = 0;
function check(name, payload, expected) {
  let got;
  try { got = verdict(run(payload)); } catch (e) { got = 'error:' + e.message; }
  const ok = got === expected;
  if (!ok) failed++;
  console.log((ok ? 'PASS' : 'FAIL') + '  ' + name + '  expected=' + expected + ' got=' + got);
}
const p = (tool, input, extra) =>
  Object.assign({ tool_name: tool, tool_input: input }, extra || {});

// transcript fixture with user marker for escape test
const tdir = fs.mkdtempSync(path.join(os.tmpdir(), 'peg-test-'));
const transcript = path.join(tdir, 't.jsonl');
fs.writeFileSync(
  transcript,
  JSON.stringify({ type: 'user', message: { role: 'user', content: '대용량허용: /tmp/big.json 데이터 fixture 필요' } }) + '\n'
);

check('Write 299 lines', p('Write', { file_path: '/tmp/a.py', content: genLines(299) }), 'allow');
check('Write 301 lines', p('Write', { file_path: '/tmp/a.py', content: genLines(301) }), 'warn');
check('Write 801 lines', p('Write', { file_path: '/tmp/a.py', content: genLines(801) }), 'deny');
check('Write byte-only deny (90KB, 3 lines)', p('Write', { file_path: '/tmp/a.js', content: 'x'.repeat(90 * 1024) + '\na\nb' }), 'deny');
check('Write byte-only warn (40KB, 10 lines)', p('Write', { file_path: '/tmp/a.js', content: Array.from({ length: 10 }, () => 'y'.repeat(4 * 1024)).join('\n') }), 'warn');
check('Edit 801-line new_string', p('Edit', { file_path: '/tmp/a.py', old_string: 'x', new_string: genLines(801) }), 'deny');
check('MultiEdit sum deny (500+400)', p('MultiEdit', { file_path: '/tmp/a.py', edits: [{ old_string: 'a', new_string: genLines(500) }, { old_string: 'b', new_string: genLines(400) }] }), 'deny');
check('MultiEdit single max deny (801+5)', p('MultiEdit', { file_path: '/tmp/a.py', edits: [{ old_string: 'a', new_string: genLines(801) }, { old_string: 'b', new_string: genLines(5) }] }), 'deny');
check('Allowlist *.lock', p('Write', { file_path: '/x/pnpm.lock', content: genLines(2000) }), 'allow');
check('Allowlist vendor/', p('Write', { file_path: '/x/vendor/lib.js', content: genLines(2000) }), 'allow');
check('Allowlist generated/', p('Write', { file_path: '/x/generated/api.ts', content: genLines(2000) }), 'allow');
check('User marker escape', p('Write', { file_path: '/tmp/big.json', content: genLines(2000) }, { transcript_path: transcript }), 'allow');
check('No marker, big write still denied', p('Write', { file_path: '/tmp/big.json', content: genLines(2000) }, { transcript_path: '/nonexistent' }), 'deny');
check('Malformed input fail-open', '{not json', 'allow');
check('NotebookEdit 801 lines', p('NotebookEdit', { notebook_path: '/tmp/n.ipynb', new_source: genLines(801) }), 'deny');

// --- bash-size-guard.js fixtures (silent below warn threshold) ---
const GUARD = path.join(__dirname, 'bash-size-guard.js');
function guardVerdict(payload) {
  const stdin = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const stdout = execSync('node ' + JSON.stringify(GUARD), { input: stdin, encoding: 'utf8' });
  if (!stdout.trim()) return 'silent';
  const h = JSON.parse(stdout).hookSpecificOutput || {};
  if (h.permissionDecision === 'deny') return 'deny';
  if ((h.additionalContext || '').includes('[분량 경고]')) return 'warn';
  return 'unknown';
}
function gcheck(name, payload, expected) {
  let got;
  try { got = guardVerdict(payload); } catch (e) { got = 'error:' + e.message; }
  const ok = got === expected;
  if (!ok) failed++;
  console.log((ok ? 'PASS' : 'FAIL') + '  [guard] ' + name + '  expected=' + expected + ' got=' + got);
}
const bp = (command, extra) => Object.assign({ tool_name: 'Bash', tool_input: { command } }, extra || {});

gcheck('small command', bp('echo hi'), 'silent');
gcheck('301-line command', bp(genLines(301)), 'warn');
gcheck('801-line heredoc', bp('cat <<EOF > big.py\n' + genLines(801) + '\nEOF'), 'deny');
gcheck('byte-only deny (90KB one line)', bp('echo "' + 'x'.repeat(90 * 1024) + '" > f'), 'deny');
gcheck('user marker escape', bp('cat <<EOF > big.json\n' + genLines(2000) + '\nEOF', { transcript_path: transcript }), 'silent');
gcheck('no command field fail-open', { tool_name: 'Bash', tool_input: {} }, 'silent');
gcheck('malformed input fail-open', '{not json', 'silent');

// --- read-size-gate.js fixtures (silent below warn threshold) ---
const RGATE = path.join(__dirname, 'read-size-gate.js');
function rVerdict(payload) {
  const stdin = typeof payload === 'string' ? payload : JSON.stringify(payload);
  const stdout = execSync('node ' + JSON.stringify(RGATE), { input: stdin, encoding: 'utf8' });
  if (!stdout.trim()) return 'silent';
  const h = JSON.parse(stdout).hookSpecificOutput || {};
  if (h.permissionDecision === 'deny') return 'deny';
  if ((h.additionalContext || '').includes('경고·강')) return 'warn-strong';
  if ((h.additionalContext || '').includes('[분량 경고]')) return 'warn';
  return 'unknown';
}
function rcheck(name, payload, expected) {
  let got;
  try { got = rVerdict(payload); } catch (e) { got = 'error:' + e.message; }
  const ok = got === expected;
  if (!ok) failed++;
  console.log((ok ? 'PASS' : 'FAIL') + '  [read] ' + name + '  expected=' + expected + ' got=' + got);
}
const mkFile = (kb) => {
  const fp = path.join(tdir, 'f' + kb + 'k.txt');
  fs.writeFileSync(fp, 'x'.repeat(kb * 1024));
  return fp;
};
const rp = (input, extra) => Object.assign({ tool_name: 'Read', tool_input: input }, extra || {});

rcheck('10KB unbounded', rp({ file_path: mkFile(10) }), 'silent');
rcheck('30KB unbounded', rp({ file_path: mkFile(30) }), 'warn');
rcheck('60KB unbounded', rp({ file_path: mkFile(60) }), 'warn-strong');
rcheck('150KB unbounded', rp({ file_path: mkFile(150) }), 'deny');
rcheck('150KB with limit', rp({ file_path: path.join(tdir, 'f150k.txt'), limit: 100 }), 'silent');
rcheck('150KB with marker', rp({ file_path: path.join(tdir, 'f150k.txt') }, { transcript_path: transcript }), 'silent');
rcheck('nonexistent file', rp({ file_path: '/no/such/file' }), 'silent');
rcheck('malformed input', '{not json', 'silent');

// --- stop-todo-gate.js fixtures ---
const SGATE = path.join(__dirname, 'stop-todo-gate.js');
const aTool = (name) => JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'tool_use', name, input: {} }] } });
const aText = (text) => JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text }] } });
const uPrompt = (t) => JSON.stringify({ type: 'user', message: { role: 'user', content: t } });
function mkTranscript(lines) {
  const fp = path.join(tdir, 'st-' + Math.abs(lines.join('').length) + '-' + lines.length + '.jsonl');
  fs.writeFileSync(fp, lines.join('\n') + '\n');
  return fp;
}
function sVerdict(tpath, active) {
  const stdout = execSync('node ' + JSON.stringify(SGATE), {
    input: JSON.stringify({ transcript_path: tpath, stop_hook_active: !!active }), encoding: 'utf8' });
  if (!stdout.trim()) return 'allow';
  return JSON.parse(stdout).decision === 'block' ? 'block' : 'unknown';
}
function scheck(name, tpath, active, expected) {
  let got;
  try { got = sVerdict(tpath, active); } catch (e) { got = 'error:' + e.message; }
  const ok = got === expected;
  if (!ok) failed++;
  console.log((ok ? 'PASS' : 'FAIL') + '  [todo] ' + name + '  expected=' + expected + ' got=' + got);
}
const work = [uPrompt('작업 요청')].concat(
  ['Edit', 'Write', 'Bash', 'Bash', 'Bash', 'Read', 'Bash', 'Bash'].map(aTool));
scheck('2 edits + 8 calls, no todo', mkTranscript(work), false, 'block');
scheck('same + TaskCreate in session', mkTranscript([uPrompt('x'), aTool('TaskCreate')].concat(work.slice(1))), false, 'allow');
scheck('read-only 10 calls', mkTranscript([uPrompt('질문')].concat(Array(10).fill(aTool('Read')))), false, 'allow');
scheck('read-heavy 21 calls, no todo', mkTranscript([uPrompt('조사')].concat(Array(21).fill(aTool('Read')))), false, 'block');
scheck('circuit breaker', mkTranscript(work), true, 'allow');
scheck('escape marker', mkTranscript(work.concat([aText('단일작업: 단순 설정 수정 2건')])), false, 'allow');

fs.rmSync(tdir, { recursive: true, force: true });
console.log(failed ? failed + ' FAILED' : 'ALL PASS');
process.exit(failed ? 1 : 0);
