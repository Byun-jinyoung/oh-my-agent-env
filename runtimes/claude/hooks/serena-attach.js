#!/usr/bin/env node
// PostToolUse(Bash) hook: when an rg/grep was a single-symbol DEFINITION lookup
// in a serena project, ask serena for the same symbol and attach its answer as
// additionalContext. rg still runs. Nothing is denied.
//
// Why this and not the gate it replaces (symbol-search-gate.js, retired
// 754658d): the gate DENIED the rg and pointed at serena. Measured over its
// life, 54% of firings re-ran the same search with the escape appended — a
// blocked model reaches for another rg, and rg found the definition in 205/205
// sampled lookups anyway, so the block bought nothing. Meanwhile the operator's
// standing instruction ("serena first for symbol lookups") sat at 0.9% of
// sessions and, on the day this was written, 0 of 45 lookups in the session
// that wrote it. Prose does not move the choice. Blocking moves it sideways.
// So: remove the choice. Both answers arrive; the model picks neither.
//
// What arrives from serena that rg cannot give: the symbol's KIND and its full
// body span (start_line..end_line), and — via find_referencing_symbols, later —
// callers. rg gives one line per textual match.
//
// Cost, and why this is async: serena's project-server answers a warm
// find_symbol in ~2.9s on the research repo (cold 7s, server start 13s). Run
// synchronously that would be the gate's +73x latency on every rg. With
// "async": true in the manifest the hook returns at once and the context is
// delivered when it lands. First call on a machine spawns the server and gives
// up quietly; the second call finds it warm.
//
// That 2.9s was self-inflicted and is gone. It measured an UNSCOPED
// find_symbol - the hook held the rg path argument and did not pass it. Scoped
// (see searchPath) the same query answers in ~255ms for a byte-identical
// result, so the async budget is now ~400ms including node start.
//
// WHEN it lands — measured 2026-08-16 on a fresh interactive session in the
// research repo, tracing the hook's own lifetime and the transcript:
//   rg ran 11:41:23Z  ->  hook POSTed at +4ms  ->  serena answered, hook
//   wrote its JSON and exited 0 at +2.9s  ->  the runtime delivered it as an
//   `attachment` record at 11:42:39Z, i.e. WITH THE NEXT USER PROMPT, and the
//   model quoted it ("serena reports the symbol span as 1071-1819", correcting
//   its own rg-based line number). Not the same turn: an async hook's
//   additionalContext reaches the model one prompt later. That is the trade
//   for not stalling every rg by 3s, and it is still zero model choice.
// In headless `claude -p` the runtime SIGTERMs the hook at +1.79s. That killed
// every unscoped query (2.9s) - the "interactive only" this file used to claim.
// A scoped query finishes at ~255ms, inside the deadline, so headless delivery
// is no longer structurally excluded; whether the runtime then surfaces it is a
// separate question this hook cannot answer for itself. A command with no
// usable path argument still falls back to the unscoped query and remains
// interactive-only.
//
// Scope, reused verbatim from the gate because the corpus tuned it (337 -> 123
// firings): a search command whose PATTERN is `def|class|function|... NAME`
// and nothing else — no alternation, no prefix sweep, no dunder, no regex meta.
// And only when cwd/.serena/project.yml exists: serena has nothing to say
// about a repo it does not index.
//
// Every failure path exits 0 with no output. This hook can add; it cannot
// subtract.
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

const DEF = /\b(?:def|class|function|func|fn|struct|interface|impl)\s+([A-Za-z_][A-Za-z0-9_]*)/;
const SEARCH_CMD = /(?:^|[|&;(]|\s)(?:rg|grep|egrep|ack|ag)\s/;
// project-server binds an OS-assigned port by default (PROJECT_SERVER_PORT = 0
// in serena's constants), so this hook pins one. Override for tests.
const SERENA_URL = process.env.OMA_SERENA_URL || 'http://127.0.0.1:24225';
// Two budgets, because the two query shapes are an order of magnitude apart
// (see searchPath). A scoped query that has not answered in 1.5s is not going
// to answer inside the headless SIGTERM either, and giving up on our own terms
// beats being killed mid-write. An unscoped one is already past that deadline
// on arrival — it only ever lands interactively, where the ceiling is the
// runtime's patience, not 1.79s.
const QUERY_TIMEOUT_SCOPED_MS = 1500;
const QUERY_TIMEOUT_MS = 8000;

// --- reused from the retired gate ---------------------------------------------
function isSingleSymbol(pattern, hit) {
  const rest = (pattern.slice(0, hit.index) + pattern.slice(hit.index + hit[0].length))
    .replace(/^\^+/, '')
    .replace(/\$+$/, '');
  if (rest !== '') return false;
  // Trailing underscore rejects prefix sweeps (`^def test_`) and dunders
  // (`def __init__` — every class has one; measured 40KB against rg's ~20KB
  // cap) in one rule. A leading underscore is a normal private def.
  return !hit[1].endsWith('_');
}
// The SEARCH PATTERN only — first non-flag argument after the rg/grep token.
// Scanning every quoted string fired on a heredoc that merely contained
// "def load_min"; the pattern argument is the one thing that says what is
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
    if (quoted !== undefined) return quoted;
    if (bare === undefined) continue;
    if (bare === '--') continue;
    if (bare.startsWith('-')) {
      if (/^-g$|^--glob$|^--iglob$/.test(bare)) tok.lastIndex = skipOne(rest, tok.lastIndex);
      continue;
    }
    return bare;
  }
  return null;
}
function skipOne(rest, from) {
  const tok = /'([^']*)'|"([^"]*)"|(\S+)/g;
  tok.lastIndex = from;
  const t = tok.exec(rest);
  return t ? tok.lastIndex : from;
}
// The PATH argument — the first non-flag token AFTER the pattern. Without it
// serena walks the whole project: measured 2026-08-17 against boltz-red with a
// warm project-server, n=3 each, byte-identical 171B answers both ways —
//   unscoped                    2727 / 2726 / 2751 ms
//   relative_path "src/boltz"    253 /  258 /  252 ms
// 10.8x, and it is the difference between an answer the headless runtime kills
// at +1.79s and one that lands with ~1.4s to spare. In the corpus every command
// that reaches this point carried a path (16/16 across the two harness
// transcripts), so this is the normal shape, not an optimisation for a corner.
//
// Checked against the filesystem before it is sent. A compound command
// (`cd x; echo "..."; rg ...`) tokenises into something that is not a path, and
// serena answers a bad relative_path with an empty array — which this hook
// cannot tell from "symbol does not exist" and would render as silence. A slow
// attach is worth more than no attach, so an unverifiable path falls back to
// the unscoped query rather than guessing.
function searchPath(cmd, cwd) {
  const m = /(?:^|[|&;(]|\s)(?:rg|grep|egrep|ack|ag)\s+([\s\S]*)$/.exec(cmd);
  if (!m) return null;
  const rest = m[1];
  const tok = /'([^']*)'|"([^"]*)"|(\S+)/g;
  let t;
  let sawPattern = false;
  while ((t = tok.exec(rest)) !== null) {
    const quoted = t[1] !== undefined ? t[1] : t[2];
    const bare = t[3];
    let val;
    if (quoted !== undefined) {
      val = quoted;
    } else if (bare === undefined) {
      continue;
    } else if (bare === '--') {
      continue;
    } else if (bare.startsWith('-')) {
      if (/^-g$|^--glob$|^--iglob$/.test(bare)) tok.lastIndex = skipOne(rest, tok.lastIndex);
      continue;
    } else {
      val = bare;
    }
    if (!sawPattern) { sawPattern = true; continue; }
    // `.` is the whole project by another name — the scan serena would do anyway.
    if (val === '.' || val === './') return null;
    try {
      if (!fs.existsSync(path.join(cwd, val))) return null;
    } catch (e) { return null; }
    return val;
  }
  return null;
}

// --- serena project-server -----------------------------------------------------
function post(url, body, timeoutMs, cb) {
  const u = new URL(url);
  const req = http.request({ host: u.hostname, port: u.port, path: '/query_project', method: 'POST',
                             headers: { 'content-type': 'application/json' }, timeout: timeoutMs },
    (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => cb(res.statusCode === 200 ? null : new Error('status ' + res.statusCode), data));
    });
  req.on('error', (e) => cb(e));
  req.on('timeout', () => { req.destroy(); cb(new Error('timeout')); });
  req.end(JSON.stringify(body));
}
// First call on a machine: no server. Spawn one detached and give up quietly;
// the next lookup finds it warm. Never awaited — this hook must not become the
// 13-second server start.
function spawnServer() {
  if (process.env.OMA_SERENA_NO_SPAWN) return;
  try {
    const u = new URL(SERENA_URL);
    const child = spawn('serena', ['start-project-server', '--port', String(u.port), '--log-level', 'ERROR'],
                        { detached: true, stdio: 'ignore' });
    child.on('error', () => {});
    child.unref();
  } catch (e) { /* no serena on PATH: nothing to attach, ever */ }
}

function render(symbol, raw) {
  let arr;
  try { arr = JSON.parse(raw); } catch (e) { return null; }
  if (!Array.isArray(arr) || arr.length === 0) return null;
  const lines = arr.slice(0, 8).map((s) => {
    const loc = s.body_location || {};
    const span = loc.start_line ? `:${loc.start_line}-${loc.end_line || loc.start_line}` : '';
    return `  ${s.kind || '?'} ${s.name_path || symbol} — ${s.relative_path || '?'}${span}`;
  });
  const more = arr.length > 8 ? `\n  (+${arr.length - 8} more)` : '';
  return `serena find_symbol("${symbol}") — the definition(s), with kind and full body span, which rg's line matches do not give:\n${lines.join('\n')}${more}`;
}

// --- main ----------------------------------------------------------------------
const stdinTimeout = setTimeout(() => process.exit(0), 5000);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { input += c; });
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  let p;
  try { p = JSON.parse(input || '{}'); } catch (e) { return process.exit(0); }
  if (p.tool_name !== 'Bash') return process.exit(0);
  const cmd = (p.tool_input && p.tool_input.command) || '';
  if (!SEARCH_CMD.test(cmd)) return process.exit(0);
  const cwd = p.cwd || process.cwd();
  if (!fs.existsSync(path.join(cwd, '.serena', 'project.yml'))) return process.exit(0);
  const pattern = searchPattern(cmd);
  if (!pattern) return process.exit(0);
  const hit = DEF.exec(pattern);
  if (!hit || !isSingleSymbol(pattern, hit)) return process.exit(0);
  const symbol = hit[1];

  const params = { name_path_pattern: symbol, include_body: false, max_answer_chars: 4000 };
  const scope = searchPath(cmd, cwd);
  if (scope) params.relative_path = scope;
  const body = { project_name: cwd, tool_name: 'find_symbol', tool_params_json: JSON.stringify(params) };
  post(SERENA_URL, body, scope ? QUERY_TIMEOUT_SCOPED_MS : QUERY_TIMEOUT_MS, (err, raw) => {
    if (err) {
      if (err.code === 'ECONNREFUSED') spawnServer();
      return process.exit(0);
    }
    const text = render(symbol, raw);
    if (!text) return process.exit(0);
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: text } }));
    process.exit(0);
  });
});
