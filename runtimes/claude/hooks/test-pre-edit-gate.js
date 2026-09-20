#!/usr/bin/env node
// Fixture tests for pre-edit-gate.js (spec: .agents deny, warn 300L/30KB,
// deny 800L/80KB, generated/vendor exemptions, fail-open).
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
  return res === null ? 'silent' : 'unknown';
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

// Retained for read-size-gate.js fixtures below.
const tdir = fs.mkdtempSync(path.join(os.tmpdir(), 'peg-test-'));
const transcript = path.join(tdir, 't.jsonl');
fs.writeFileSync(
  transcript,
  JSON.stringify({ type: 'user', message: { role: 'user', content: '대용량허용: /tmp/big.json 데이터 fixture 필요' } }) + '\n'
);

const agentsPath = (suffix) => path.join(process.cwd(), '.agents', suffix);
const agentsAliasPath = (suffix) => process.cwd() + '/hooks/../.agents/' + suffix;
const symlinkRoot = path.join(tdir, 'symlink-root');
const symlinkTarget = path.join(tdir, 'symlink-target');
fs.mkdirSync(symlinkRoot);
fs.mkdirSync(symlinkTarget);
fs.symlinkSync(symlinkTarget, path.join(symlinkRoot, '.agents'));

check('Write 299 lines is silent', p('Write', { file_path: '/tmp/a.py', content: genLines(299) }), 'silent');
check('Write 301 lines', p('Write', { file_path: '/tmp/a.py', content: genLines(301) }), 'warn');
check('Write 801 lines', p('Write', { file_path: '/tmp/a.py', content: genLines(801) }), 'deny');
check('Write byte-only deny (90KB, 3 lines)', p('Write', { file_path: '/tmp/a.js', content: 'x'.repeat(90 * 1024) + '\na\nb' }), 'deny');
check('Write byte-only warn (40KB, 10 lines)', p('Write', { file_path: '/tmp/a.js', content: Array.from({ length: 10 }, () => 'y'.repeat(4 * 1024)).join('\n') }), 'warn');
check('Edit 801-line new_string', p('Edit', { file_path: '/tmp/a.py', old_string: 'x', new_string: genLines(801) }), 'deny');
check('MultiEdit sum deny (500+400)', p('MultiEdit', { file_path: '/tmp/a.py', edits: [{ old_string: 'a', new_string: genLines(500) }, { old_string: 'b', new_string: genLines(400) }] }), 'deny');
check('MultiEdit single max deny (801+5)', p('MultiEdit', { file_path: '/tmp/a.py', edits: [{ old_string: 'a', new_string: genLines(801) }, { old_string: 'b', new_string: genLines(5) }] }), 'deny');
check('Allowlist *.lock is silent', p('Write', { file_path: '/x/pnpm.lock', content: genLines(2000) }), 'silent');
check('Allowlist vendor/ is silent', p('Write', { file_path: '/x/vendor/lib.js', content: genLines(2000) }), 'silent');
check('Allowlist generated/ is silent', p('Write', { file_path: '/x/generated/api.ts', content: genLines(2000) }), 'silent');
check('Transcript marker cannot bypass large write', p('Write', { file_path: '/tmp/big.json', content: genLines(2000) }, { transcript_path: transcript }), 'deny');
check('Write .agents destination denied', p('Write', { file_path: agentsPath('oma-config.yaml'), content: 'x' }), 'deny');
check('Edit .agents alias destination denied', p('Edit', { file_path: agentsAliasPath('oma-config.yaml'), old_string: 'x', new_string: 'y' }), 'deny');
check('MultiEdit .agents destination denied', p('MultiEdit', { file_path: agentsPath('rules.md'), edits: [{ old_string: 'x', new_string: 'y' }] }), 'deny');
check('NotebookEdit .agents alias destination denied', p('NotebookEdit', { notebook_path: agentsAliasPath('notebook.ipynb'), new_source: 'x' }), 'deny');
check('Relative .agents destination uses hook cwd', p('Write', { file_path: '.agents/state.json', content: 'x' }, { cwd: tdir }), 'deny');
check('Another project .agents destination denied', p('Write', { file_path: '/tmp/elsewhere/.agents/state.json', content: 'x' }), 'deny');
check('Symlinked lexical .agents destination denied', p('Write', { file_path: '.agents/state.json', content: 'x' }, { cwd: symlinkRoot }), 'deny');
check('Malformed input fail-open', '{not json', 'silent');
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
gcheck('transcript marker cannot bypass oversized command', bp('cat <<EOF > big.json\n' + genLines(2000) + '\nEOF', { transcript_path: transcript }), 'deny');
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
rcheck('150KB marker cannot bypass', rp({ file_path: path.join(tdir, 'f150k.txt') }, { transcript_path: transcript }), 'deny');
rcheck('nonexistent file', rp({ file_path: '/no/such/file' }), 'silent');
rcheck('malformed input', '{not json', 'silent');

fs.rmSync(tdir, { recursive: true, force: true });
console.log(failed ? failed + ' FAILED' : 'ALL PASS');
process.exit(failed ? 1 : 0);
