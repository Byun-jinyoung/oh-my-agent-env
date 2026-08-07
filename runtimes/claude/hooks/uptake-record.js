#!/usr/bin/env node
// SessionEnd hook: append one behavioural row per session.
//
// Everything this harness learned about itself came from scanning
// ~/.claude/projects by hand. That scan takes 30-60s over 8809 files, so it
// only ever ran when someone remembered — which is the exact failure mode the
// measurements keep finding everywhere else (prose-only channels: 0-5%).
// A measurement that depends on being remembered cannot be used to check
// whether a fix that removes remembering actually worked.
//
// So: incremental. At SessionEnd, scan only the session that just ended and
// append a row. The trend is read from rows, never by rescanning. Measured
// cost on this session's transcript (35MB, 26578 lines): 0.13s.
//
// The transcript is located by globbing the session id rather than by encoding
// cwd into a directory name. The encoding (/ and . both become -) is not a
// documented contract, and a row silently going missing is worse than a slower
// lookup across 16 directories.
//
// Two of the counters exist to answer one open question — whether
// symbol-search-gate.js works: `nav.serena` should rise from its 0.9% baseline,
// and `gate.escape` is the false-positive alarm. If the escape is used often,
// the gate is firing on searches it should not.
//
// Silent, side-effect-only, fail-open: a SessionEnd hook must never speak and
// must never be able to hold up a session ending.
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = os.homedir();
const OUT_DIR = process.env.OMA_UPTAKE_DIR || path.join(HOME, '.claude', 'uptake');
const PROJECTS = process.env.OMA_PROJECTS_DIR || path.join(HOME, '.claude', 'projects');

function findTranscript(sessionId) {
  if (!sessionId || sessionId === '-' || !fs.existsSync(PROJECTS)) return null;
  for (const d of fs.readdirSync(PROJECTS)) {
    const p = path.join(PROJECTS, d, sessionId + '.jsonl');
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function scan(file) {
  const nav = { rg: 0, serena: 0, lsp: 0, ast_grep: 0, graphify: 0, toolsearch: 0 };
  const gate = { denied: 0, escape: 0 };
  const fail = { bash: 0, edit: 0 };
  const reads = { full: 0, ranged: 0, dup: 0 };
  const tools = {};
  const seenRead = new Set();
  const idName = new Map();
  const RG = /(?:^|[|&;(]|\s)(?:rg|grep|egrep|ack|ag)\s/;

  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line || line.indexOf('"tool_') === -1) continue;
    let row;
    try { row = JSON.parse(line); } catch (e) { continue; }
    const content = ((row.message || {}).content) || [];
    if (!Array.isArray(content)) continue;
    for (const c of content) {
      if (!c || typeof c !== 'object') continue;
      if (c.type === 'tool_use') {
        const n = c.name || '';
        const inp = c.input || {};
        tools[n] = (tools[n] || 0) + 1;
        idName.set(c.id, n);
        if (n === 'ToolSearch') nav.toolsearch++;
        if (n.indexOf('mcp__serena__') === 0) nav.serena++;
        if (n.indexOf('lsp_') !== -1) nav.lsp++;
        if (n.indexOf('ast_grep') !== -1) nav.ast_grep++;
        if (n === 'Read') {
          const fp = inp.file_path || '';
          if (inp.offset || inp.limit) reads.ranged++; else reads.full++;
          if (seenRead.has(fp)) reads.dup++; else seenRead.add(fp);
        }
        if (n === 'Bash') {
          const cmd = inp.command || '';
          if (RG.test(cmd)) nav.rg++;
          if (cmd.indexOf('graphify') !== -1) nav.graphify++;
          if (cmd.indexOf('텍스트검색:') !== -1) gate.escape++;
        }
      } else if (c.type === 'tool_result') {
        const n = idName.get(c.tool_use_id) || '';
        const body = typeof c.content === 'string' ? c.content : JSON.stringify(c.content || '');
        if (body.indexOf('[탐색 게이트]') !== -1) gate.denied++;
        if (c.is_error) {
          if (n === 'Bash') fail.bash++;
          else if (n === 'Edit' || n === 'Write' || n === 'NotebookEdit') fail.edit++;
        }
      }
    }
  }
  return { nav, gate, fail, reads, calls: Object.values(tools).reduce((a, b) => a + b, 0) };
}

const stdinTimeout = setTimeout(() => process.exit(0), 5000);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (input += c));
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const p = JSON.parse(input || '{}');
    const file = p.transcript_path && fs.existsSync(p.transcript_path)
      ? p.transcript_path
      : findTranscript(p.session_id);
    if (!file) return process.exit(0);
    const m = scan(file);
    // A session that used no tools says nothing about tool choice, and would
    // dilute every rate computed from these rows.
    if (m.calls === 0) return process.exit(0);
    fs.mkdirSync(OUT_DIR, { recursive: true });
    fs.appendFileSync(
      path.join(OUT_DIR, 'rows.jsonl'),
      JSON.stringify(Object.assign(
        { ts: new Date().toISOString(), session: p.session_id || '-', cwd: p.cwd || '-', reason: p.reason || '-' },
        m
      )) + '\n'
    );
  } catch (e) {
    /* fail-open */
  }
  return process.exit(0);
});
