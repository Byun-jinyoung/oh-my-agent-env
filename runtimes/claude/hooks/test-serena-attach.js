#!/usr/bin/env node
// Fixture tests for serena-attach.js — the hook that ATTACHES a serena answer
// to an rg definition lookup instead of denying the lookup.
//
// The gate this replaces (symbol-search-gate.js, retired 754658d) denied the
// rg and pointed at serena; 54% of firings re-ran the same search with the
// escape appended, because a blocked model reaches for another rg. This hook
// makes no demand: rg runs, and if the query was a single-symbol definition
// lookup in a serena project, serena's answer arrives beside it. Nothing to
// route around.
//
// The serena side is faked with OMA_SERENA_URL pointing at a stub server the
// test starts, so these fixtures assert the hook's contract, not serena's:
//   - which commands qualify (reuses the corpus-tuned rules: 337 -> 123),
//   - what is sent to /query_project,
//   - what comes back as additionalContext, and
//   - that every failure path exits 0 with no output (attach, never block).
//
// Run: node test-serena-attach.js  -> exits non-zero on any failure.
'use strict';
const { spawn, spawnSync } = require('child_process');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOOK = path.join(__dirname, 'serena-attach.js');
const tdir = fs.mkdtempSync(path.join(os.tmpdir(), 'serena-attach-'));
const proj = path.join(tdir, 'proj');
fs.mkdirSync(path.join(proj, '.serena'), { recursive: true });
fs.writeFileSync(path.join(proj, '.serena', 'project.yml'), 'project_name: proj\nlanguages: [python]\n');
const noserena = path.join(tdir, 'plain');
fs.mkdirSync(noserena);

let failed = 0;
function check(name, cond, detail) {
  if (!cond) { failed++; console.log('FAIL  ' + name + (detail ? '  ' + detail : '')); }
  else console.log('PASS  ' + name);
}

// --- stub serena project-server ------------------------------------------------
const seen = [];
let reply = () => JSON.stringify([{ name_path: 'Boltz2', kind: 'Class', relative_path: 'src/boltz/model/models/boltz2.py', body_location: { start_line: 41, end_line: 1568 } }]);
const srv = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    if (req.url === '/heartbeat') { res.end('{"status":"alive"}'); return; }
    seen.push(JSON.parse(body));
    const out = reply();
    if (out === null) { res.statusCode = 500; res.end('boom'); return; }
    res.end(out);
  });
});

// Async, not spawnSync: the stub server lives in THIS process, and a
// synchronous spawn blocks the event loop the stub needs to answer — the hook
// then waits on a server that can never reply, times out, and every "attaches"
// case fails for a reason that has nothing to do with the hook. Found on the
// first run.
function runHook(payload, env) {
  return new Promise((resolve) => {
    const child = spawn('node', [HOOK], {
      env: Object.assign({}, process.env, { OMA_SERENA_URL: 'http://127.0.0.1:' + srv.address().port, OMA_SERENA_NO_SPAWN: '1' }, env || {}),
    });
    let out = '', err = '';
    child.stdout.on('data', (c) => { out += c; });
    child.stderr.on('data', (c) => { err += c; });
    const t = setTimeout(() => child.kill(), 15000);
    child.on('close', (code) => { clearTimeout(t); resolve({ code, out: out.trim(), err }); });
    child.stdin.end(JSON.stringify(payload));
  });
}
function bash(cmd, cwd) {
  return { session_id: 't', transcript_path: '/dev/null', cwd: cwd || proj, hook_event_name: 'PostToolUse',
           tool_name: 'Bash', tool_input: { command: cmd }, tool_response: { stdout: 'x', stderr: '' } };
}
function ctx(r) {
  try { return JSON.parse(r.out).hookSpecificOutput.additionalContext; } catch (e) { return null; }
}

srv.listen(0, '127.0.0.1', async () => {
  // --- fires: single-symbol definition lookups in a serena project ------------
  let r = await runHook(bash('rg "def get_potentials" src/'));
  check('def lookup attaches serena result', r.code === 0 && ctx(r) && ctx(r).includes('boltz2.py'), r.out || r.err);
  check('sends find_symbol for the symbol, not the pattern', seen.length === 1 && seen[0].tool_name === 'find_symbol'
        && JSON.parse(seen[0].tool_params_json).name_path_pattern === 'get_potentials', JSON.stringify(seen[0]));
  check('project_name is the cwd', seen[0].project_name === proj, seen[0].project_name);
  check('context names the tool that answered', ctx(r).indexOf('serena') !== -1, ctx(r));

  seen.length = 0;
  r = await runHook(bash("grep -rn 'class Boltz2' src/boltz"));
  check('class lookup via grep -rn attaches', r.code === 0 && ctx(r) !== null, r.out || r.err);
  r = await runHook(bash('rg -n "^def _validate_shapes"', proj));
  check('leading underscore is a normal private def — attaches', ctx(r) !== null, r.out);

  // --- silent: everything the corpus said serena cannot answer ---------------
  seen.length = 0;
  const silent = [
    ['plain text search', 'rg "TODO" src/'],
    ['alternation — no single symbol', 'rg "def (foo|bar)" src/'],
    ['prefix sweep (trailing underscore)', 'rg "^def test_" tests/'],
    ['dunder — every class defines one', 'rg "def __init__" src/'],
    ['regex meta in the symbol', 'rg "def load.*min" src/'],
    ['definition text inside a heredoc, not a search', 'python3 - <<EOF\nprint("def load_min")\nEOF'],
    ['glob value shaped like a definition', 'rg -g "class Foo*" TODO src/'],
    ['not a search command', 'ls -la src/'],
    ['no serena project at cwd', null],
  ];
  for (const [name, cmd] of silent) {
    const p = cmd === null ? bash('rg "def get_potentials" src/', noserena) : bash(cmd);
    r = await runHook(p);
    check('silent: ' + name, r.code === 0 && r.out === '', 'code=' + r.code + ' out=' + r.out);
  }
  // A non-Bash tool whose input happens to carry a `command` string (an MCP
  // shell tool, say). The matcher in the manifest is Bash, but the hook must
  // not depend on the manifest to be right about that.
  const notBash = bash('rg "def get_potentials" src/'); notBash.tool_name = 'mcp__something__run';
  r = await runHook(notBash);
  check('silent: not the Bash tool, even with a command field', r.code === 0 && r.out === '', 'out=' + r.out);
  check('silent cases never called serena', seen.length === 0, seen.length + ' calls');

  // --- serena says nothing / breaks: still silent, still exit 0 ---------------
  reply = () => '[]';
  r = await runHook(bash('rg "def compute_rmsd" src/'));
  check('empty serena result -> no context (rg already answered)', r.code === 0 && r.out === '', r.out);
  reply = () => null;
  r = await runHook(bash('rg "def get_potentials" src/'));
  check('serena 500 -> silent exit 0', r.code === 0 && r.out === '', 'code=' + r.code + ' out=' + r.out);
  reply = () => 'not json at all';
  r = await runHook(bash('rg "def get_potentials" src/'));
  check('serena non-JSON -> silent exit 0', r.code === 0 && r.out === '', r.out);

  // --- serena unreachable and spawning disabled: silent, exit 0 ---------------
  r = await runHook(bash('rg "def get_potentials" src/'), { OMA_SERENA_URL: 'http://127.0.0.1:1' });
  check('server down (no spawn) -> silent exit 0', r.code === 0 && r.out === '', 'code=' + r.code + ' out=' + r.out);

  // --- garbage stdin -----------------------------------------------------------
  const g = spawnSync('node', [HOOK], { input: '{not json', encoding: 'utf8', env: Object.assign({}, process.env, { OMA_SERENA_NO_SPAWN: '1' }), timeout: 15000 });
  check('garbage stdin -> silent exit 0', g.status === 0 && (g.stdout || '').trim() === '', 'code=' + g.status);

  srv.close();
  console.log(failed ? 'serena-attach: ' + failed + ' failure(s)' : 'serena-attach: OK');
  process.exit(failed ? 1 : 0);
});
