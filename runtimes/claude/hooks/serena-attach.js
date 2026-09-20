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
// delivered when it lands. The managed systemd unit is the sole server owner;
// an unavailable server is recorded and never replaced by a competing process.
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
// Headless `claude -p` does not deliver this, and the reason is NOT the +1.79s
// SIGTERM this file blamed. Traced 2026-08-17 in the boltz-red worktree over a
// resumed session: the hook ran to completion and wrote its ledger row
// (outcome scoped, 1144ms - well inside the window), and the transcript for
// that session contains zero async_hook_response records. The next `-p` turn,
// asked to quote any hook context it received, answered "none". A one-shot
// invocation exits before an async hook's output can be attached to a prompt
// that this process will never see, so making the query fast does not fix it.
// Interactive only, still - but now for the real reason, and the ledger is
// what distinguishes "the hook failed" from "the runtime never delivered it".
// The latency work stands on its own: interactive delivery costs ~255ms of
// project-server time instead of ~2.9s (3343ms on the first query after the
// project-server restarts, before the project is loaded).
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
const os = require('os');
const path = require('path');
const http = require('http');

// One line per firing, because the transcript records only the attachments
// that ARRIVED. A scoped hit and a query the runtime killed look identical
// from there - both absent - and so do a fallback that took 3s and a scoped
// query that took 255ms. Without this the fallback rate is unobservable and
// "293ms" silently describes only the paths that happened to hit.
// Written with the session id the hook is already given, so rows join to the
// SessionEnd ledger. Silent and fail-open like everything else here: a
// counter that can break the hook is worse than no counter.
const LEDGER = path.join(process.env.OMA_UPTAKE_DIR || path.join(os.homedir(), '.claude', 'uptake'), 'attach.jsonl');
const started = Date.now();
let terminalRecorded = false;
let SESSION = '-';
let EVENT_ID = null;
let ATTEMPT = null;
function record(type, extra) {
  try {
    fs.mkdirSync(path.dirname(LEDGER), { recursive: true });
    fs.appendFileSync(LEDGER, JSON.stringify(Object.assign({
      schema_version: 1,
      record_type: type,
      ts: new Date().toISOString(),
      event_id: EVENT_ID,
      session_id: SESSION,
      initiation: 'model',
      mode: 'unknown',
      delivery_eligible: 'unknown',
    }, extra || {})) + '\n');
  } catch (e) { /* a ledger that cannot be written is not a reason to fail */ }
}
function done(outcome, extra) {
  if (!terminalRecorded) {
    terminalRecorded = true;
    const terminal = Object.assign({ outcome: outcome }, ATTEMPT || {}, extra || {});
    if (outcome !== 'unjoinable') terminal.query_ms = Date.now() - started;
    record('attempt_terminal', terminal);
  }
  process.exit(0);
}

const DEF = /\b(?:def|class|function|func|fn|struct|interface|impl)\s+([A-Za-z_][A-Za-z0-9_]*)/;
const SEARCH_CMD = /(?:^|[|&;(]|\s)(?:rg|grep|egrep|ack|ag)\s/;
// project-server binds an OS-assigned port by default (PROJECT_SERVER_PORT = 0
// in serena's constants), so this hook pins one. Override for tests.
const SERENA_URL = process.env.OMA_SERENA_URL || 'http://127.0.0.1:24225';
// One budget, sized for a cold project rather than a warm one. This was split
// (1500ms scoped / 8000ms otherwise) so a scoped query would give up before
// the headless +1.79s SIGTERM instead of being killed mid-write. Then headless
// turned out not to deliver at any latency, which left the short budget buying
// nothing and costing the first lookup after every server restart: measured
// against boltz-red immediately after `systemctl --user kill`, the first query
// takes 3343ms (project load + language server) and the next three take 255ms.
// 1500ms discarded exactly the query that had to pay for the others.
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
function render(symbol, raw) {
  let arr;
  try { arr = JSON.parse(raw); } catch (e) { return null; }
  if (!Array.isArray(arr) || arr.length === 0) return null;
  const lines = arr.slice(0, 8).map((s) => {
    const loc = s.body_location || {};
    // Serena locations are zero-based; user-facing file tools and editors are
    // one-based. Preserve a legitimate zero instead of treating it as absent.
    const hasStart = Number.isInteger(loc.start_line);
    const startLine = hasStart ? loc.start_line + 1 : null;
    const endLine = Number.isInteger(loc.end_line) ? loc.end_line + 1 : startLine;
    const span = hasStart ? `:${startLine}-${endLine}` : '';
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
  SESSION = typeof p.session_id === 'string' && p.session_id ? p.session_id : '-';
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
  const scope = searchPath(cmd, cwd);
  EVENT_ID = typeof p.tool_use_id === 'string' && p.tool_use_id ? p.tool_use_id : null;
  ATTEMPT = { symbol: symbol, scope: scope || null };
  // `tool_use_id` is the only stable join key supplied by PostToolUse. Do not
  // turn a session, command, or content hash into an identity: those collide.
  record('opportunity', Object.assign({ outcome: 'eligible' }, ATTEMPT));
  if (!EVENT_ID) return done('unjoinable');
  record('attempt_started', Object.assign({ outcome: 'started' }, ATTEMPT));

  const params = { name_path_pattern: symbol, include_body: false, max_answer_chars: 4000 };
  if (scope) params.relative_path = scope;
  const body = { project_name: cwd, tool_name: 'find_symbol', tool_params_json: JSON.stringify(params) };
  post(SERENA_URL, body, QUERY_TIMEOUT_MS, (err, raw) => {
    const shape = scope ? 'scoped' : 'fallback';
    if (err) {
      const outcome = err.message === 'timeout' ? 'timeout' : 'error';
      return done(outcome, {
        shape: shape,
        symbol: symbol,
        error_class: err.code === 'ECONNREFUSED' ? 'server_unavailable' : outcome,
      });
    }
    const text = render(symbol, raw);
    if (!text) return done('empty', { shape: shape });
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        additionalContext: text + `\n<!-- oma-serena-event:${EVENT_ID} -->`,
      },
    }));
    done('attached', { shape: shape });
  });
});
