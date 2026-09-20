#!/usr/bin/env node
'use strict';
// Fixture tests for graph-impact-attach.js. The graph tools are PATH stubs so
// these assert the hook's event boundary, lifecycle ledger, and attachment
// contract without querying any real graph.
const assert = require('assert');
const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOOK = path.join(__dirname, 'graph-impact-attach.js');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'graph-impact-attach-'));
const root = path.join(tmp, 'repo');
const bin = path.join(tmp, 'bin');
const noTools = path.join(tmp, 'no-tools');
const uptake = path.join(tmp, 'uptake');
fs.mkdirSync(path.join(root, 'src'), { recursive: true });
fs.mkdirSync(path.join(root, 'graphify-out'), { recursive: true });
fs.mkdirSync(bin);
fs.mkdirSync(noTools);
fs.writeFileSync(path.join(root, 'graphify-out', 'graph.json'), '{}');
spawnSync('git', ['init', '-q', root], { encoding: 'utf8' });
const gitPath = (process.env.PATH || '').split(path.delimiter).map((entry) => path.join(entry, 'git'))
  .find((candidate) => fs.existsSync(candidate));
if (gitPath) fs.symlinkSync(gitPath, path.join(noTools, 'git'));

const graphify = `#!/usr/bin/env node
const fs = require('fs');
fs.appendFileSync(process.env.GRAPH_IMPACT_LOG, 'graphify ' + process.argv.slice(2).join(' ') + '\\n');
process.stdout.write('dependency context: src/a.js -> src/c.js\\n');
process.exit(process.env.GRAPHIFY_FAIL ? 9 : 0);
`;
const reviewGraph = `#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.GRAPH_IMPACT_LOG, 'crg ' + args.join(' ') + '\\n');
if (process.env.CRG_FAIL && args[0] === process.env.CRG_FAIL) process.exit(7);
if (args[0] === 'detect-changes') process.stdout.write('brief impact: src/a.js -> src/c.js\\nverbose details that must not become a graph dump');
`;
fs.writeFileSync(path.join(bin, 'graphify'), graphify, { mode: 0o755 });
fs.writeFileSync(path.join(bin, 'code-review-graph'), reviewGraph, { mode: 0o755 });

function assistant(id, file, name) {
  return { type: 'assistant', message: { content: [{ type: 'tool_use', id: id, name: name || 'Write', input: { file_path: file } }] } };
}
function failedResult(id) {
  return { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: id, is_error: true, content: 'failed' }] } };
}
function transcript(records) {
  const file = path.join(tmp, 'transcript-' + Math.random().toString(36).slice(2) + '.jsonl');
  fs.writeFileSync(file, [{ type: 'user', message: { content: 'make the change' } }].concat(records)
    .map((record) => JSON.stringify(record)).join('\n') + '\n');
  return file;
}
function payload(file, id) {
  const p = { session_id: 'test-session', transcript_path: file, cwd: root, tool_name: 'Write', tool_input: { file_path: 'src/c.js' } };
  if (id !== undefined) p.tool_use_id = id;
  return p;
}
function run(p, extra) {
  return new Promise((resolve, reject) => {
    const env = Object.assign({}, process.env, {
      PATH: bin + path.delimiter + process.env.PATH,
      OMA_UPTAKE_DIR: uptake,
      GRAPH_IMPACT_LOG: path.join(tmp, 'commands.log'),
    }, extra || {});
    const child = spawn(process.execPath, [HOOK], { env: env });
    let out = '', err = '';
    child.stdout.on('data', (chunk) => { out += chunk; });
    child.stderr.on('data', (chunk) => { err += chunk; });
    const timer = setTimeout(() => child.kill('SIGKILL'), 30000);
    child.on('close', (code) => { clearTimeout(timer); resolve({ code, out: out.trim(), err: err.trim() }); });
    child.on('error', reject);
    child.stdin.end(JSON.stringify(p));
  });
}
function rows() {
  try {
    return fs.readFileSync(path.join(uptake, 'opportunity.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  } catch (e) { return []; }
}
function commands() {
  try { return fs.readFileSync(path.join(tmp, 'commands.log'), 'utf8').trim().split('\n').filter(Boolean); } catch (e) { return []; }
}
function clear() {
  fs.rmSync(uptake, { recursive: true, force: true });
  fs.rmSync(path.join(tmp, 'commands.log'), { force: true });
}
let failed = 0;
function check(name, condition, detail) {
  if (condition) console.log('PASS  ' + name);
  else { failed++; console.log('FAIL  ' + name + (detail ? '  ' + detail : '')); }
}

(async () => {
  clear();
  let r = await run(payload(transcript([assistant('one', 'src/a.js')]), 'one'));
  check('one source file is silent', r.code === 0 && !r.out && commands().length === 0 && rows().length === 0, r.out || JSON.stringify(rows()));
  r = await run(payload(transcript([assistant('one', 'src/a.js'), assistant('two', 'src/b.js')]), 'two'));
  check('two source files are silent', r.code === 0 && !r.out && commands().length === 0 && rows().length === 0, r.out || JSON.stringify(rows()));

  clear();
  const third = transcript([assistant('one', 'src/a.js'), assistant('two', 'src/b.js'), assistant('three', 'src/c.js')]);
  r = await run(payload(third, 'three'));
  const context = (() => { try { return JSON.parse(r.out).hookSpecificOutput.additionalContext; } catch (e) { return ''; } })();
  check('third distinct source file triggers once', r.code === 0 && commands().length === 2 && rows().filter((row) => row.record_type === 'opportunity').length === 1, JSON.stringify({ r, commands: commands(), rows: rows() }));
  check('commands query Graphify then request read-only CRG impact', commands().length === 2
    && commands()[0].startsWith('graphify query ')
    && commands()[0].includes('src/a.js src/b.js src/c.js')
    && commands()[0].includes('--budget 800 --graph ')
    && commands()[1].startsWith('crg detect-changes --base HEAD --brief --repo '), commands().join(' | '));
  check('success attaches event id and only brief impact', context.includes('<!-- oma-graph-impact-event:three -->')
    && context.includes('dependency context:') && context.includes('brief impact:')
    && context.includes('CRG impact (all uncommitted worktree changes):'), context);
  r = await run(payload(transcript([
    assistant('one', 'src/a.js'), assistant('two', 'src/b.js'), assistant('three', 'src/c.js'), assistant('four', 'src/d.js'),
  ]), 'four'));
  check('fourth source file does not retrigger', r.code === 0 && !r.out && commands().length === 2, r.out || commands().join(' | '));

  clear();
  r = await run(payload(transcript([
    assistant('doc', 'docs/guide.md'), assistant('config', 'config/tool.ts'),
    assistant('generated', 'generated/api.ts'), assistant('outside', path.join(tmp, 'outside.js')),
    assistant('one', 'src/a.js'), assistant('two', 'src/b.js'), assistant('three', 'src/c.js'),
  ]), 'three'));
  check('docs config generated and outside-root destinations are excluded', r.code === 0 && commands().length === 2, JSON.stringify({ r, commands: commands() }));

  clear();
  r = await run(payload(transcript([
    assistant('failed', 'src/failed.js'), failedResult('failed'),
    assistant('one', 'src/a.js'), assistant('two', 'src/b.js'),
  ]), 'two'));
  check('failed prior edits do not count toward the three-file boundary',
    r.code === 0 && !r.out && commands().length === 0 && rows().length === 0,
    JSON.stringify({ r, commands: commands(), rows: rows() }));

  clear();
  r = await run(payload(third, undefined));
  check('missing tool_use_id records explicit terminal without inventing an id', r.code === 0 && !r.out
    && rows().some((row) => row.record_type === 'opportunity' && row.outcome === 'missing_tool_use_id' && row.event_id === null)
    && rows().some((row) => row.record_type === 'attempt_terminal' && row.outcome === 'missing_tool_use_id' && row.event_id === null), JSON.stringify(rows()));

  clear();
  r = await run(payload(transcript([
    assistant('one', 'src/a.js'), assistant('two', 'src/b.js'),
    assistant('three', 'src/c.js'), assistant('repeat', 'src/c.js'),
  ]), undefined));
  check('missing-id repeated edit after the third file does not inflate opportunities',
    r.code === 0 && !r.out && rows().length === 0, JSON.stringify(rows()));

  clear();
  r = await run(payload(transcript([
    assistant('one', 'src/a.js'), assistant('two', 'src/b.js'),
    { type: 'user', isMeta: true, message: { content: [{ type: 'text', text: 'slash expansion' }] } },
    assistant('three', 'src/c.js'),
  ]), 'three'));
  check('meta user rows do not reset the current turn boundary',
    r.code === 0 && commands().length === 2
      && rows().some((row) => row.record_type === 'attempt_terminal' && row.outcome === 'attached'),
    JSON.stringify({ r, commands: commands(), rows: rows() }));

  clear();
  fs.rmSync(path.join(root, 'graphify-out', 'graph.json'));
  r = await run(payload(third, 'three'));
  check('missing graph prerequisite records explicit terminal', r.code === 0 && !r.out
    && rows().some((row) => row.record_type === 'attempt_terminal' && row.outcome.includes('graphify_graph_missing')),
  JSON.stringify(rows()));
  fs.writeFileSync(path.join(root, 'graphify-out', 'graph.json'), '{}');

  clear();
  r = await run(payload(third, 'three'), { PATH: noTools });
  check('missing graph executables record an explicit terminal', r.code === 0 && !r.out
    && rows().some((row) => row.record_type === 'attempt_terminal'
      && row.outcome === 'graphify_missing_and_code_review_graph_missing'), JSON.stringify(rows()));

  clear();
  r = await run(payload(third, 'three'), { CRG_FAIL: 'detect-changes' });
  check('command failure records terminal outcome and stage latency', r.code === 0 && !r.out
    && rows().some((row) => row.record_type === 'attempt_terminal' && row.outcome === 'code_review_graph_detect_changes_failed'
      && row.stages.some((stage) => stage.stage === 'code_review_graph_detect_changes' && stage.latency_ms >= 0)), JSON.stringify(rows()));

  console.log(failed ? 'graph-impact-attach: ' + failed + ' failure(s)' : 'graph-impact-attach: OK');
  process.exit(failed ? 1 : 0);
})().catch((err) => { console.error(err.stack || err); process.exit(1); });
