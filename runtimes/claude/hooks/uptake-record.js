#!/usr/bin/env node
// SessionEnd hook: append one behavioural row per SessionEnd.
//
// NOT one row per session, which is what this line said until 2026-08-14 and
// what scripts/measure-uptake.sh was written to believe. A session ends more
// than once — exit, clear, logout, prompt_input_exit, resume all fire SessionEnd
// — and each firing rescans the whole transcript (see scan() below: no cursor,
// no delta), so the rows for one session are cumulative snapshots of the same
// growing file. Summing them counts the same tool call once per ending. On the
// real ledger that was 72 rows over 50 sessions, one session holding 10, and it
// inflated rg by 217% and serena by 250% in numbers this harness had already
// quoted as evidence. Consumers must group by `session` before adding anything.
//
// Everything this harness learned about itself came from scanning
// ~/.claude/projects by hand, and that scan only ever ran when someone
// remembered — the exact failure mode the measurements keep finding everywhere
// else (prose-only channels: 0-5%). A measurement that depends on being
// remembered cannot be used to check whether a fix that removes remembering
// actually worked.
//
// Speed is NOT the argument, though an earlier version of this comment claimed
// "30-60s over 8809 files". Measured 2026-08-14: 6.8s over 10,675 files. The
// full scan is cheap; it is simply never run. Being wrong about this mattered —
// a false cost would have justified this hook on its own, and the only real
// justification is the remembering.
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
// The gate.* counters were added to answer whether symbol-search-gate.js
// worked. It did not (rg found the definition in 205/205 lookups; serena was
// 73x slower and every redirected call in the target repo hit "No active
// project"), and it was retired 2026-08-16. The counters stay: rows written
// while it ran are the record of that, and a scanner that stops emitting a
// key makes old rows look like they never carried it.
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
  // ocr / semantica added 2026-08-16 with the tools themselves (sync installs
  // them; see lib/sync/external-tools.sh). The 2026-08-07 survey predicted
  // 0-5% uptake for anything the model must choose to call; these are the
  // numbers that check that prediction. Present at 0 from day one so a row
  // that carries the key at 0 means "installed and unused", and a row without
  // the key means "predates the counter" — the consumer renders only rows
  // that carry it.
  const nav = { rg: 0, serena: 0, serena_err: 0, lsp: 0, ast_grep: 0, graphify: 0, toolsearch: 0,
                ocr: 0, semantica: 0, serena_attached: 0 };
  // Skill loads are not navigation; karpathy-guidelines is a norm the model
  // opts into, and whether it ever does is the whole question about it.
  const skills = { karpathy: 0, ponytail: 0 };
  // `denied` counts firings; the `to_*` counters say what the firing achieved.
  // A denial rate cannot tell a working gate from one the model routes around:
  // in the 28 firings recorded so far, 21% reached serena and 54% re-ran the
  // same search with the escape comment appended. Deciding whether to keep,
  // tighten or drop the gate needs the outcome, and computing it by hand from
  // transcripts is the remembered measurement this file exists to replace.
  const gate = { denied: 0, escape: 0, to_serena: 0, to_escape: 0, to_rg: 0, to_read: 0, to_other: 0 };
  const fail = { bash: 0, edit: 0 };
  const reads = { full: 0, ranged: 0, dup: 0 };
  const tools = {};
  const seenRead = new Set();
  const idName = new Map();
  const RG = /(?:^|[|&;(]|\s)(?:rg|grep|egrep|ack|ag)\s/;
  // Same shape as RG: the binary in command position, not the substring. `ocr`
  // is three letters and appears inside docr/, ocrypt.py, /tmp/ocr-notes.txt.
  const OCR = /(?:^|[|&;(]|\s)ocr(?:\s|$)/;
  // Linear event trace, needed because the outcome of a denial is whatever tool
  // runs NEXT — which is not knowable at the moment the denial is read.
  const trace = [];

  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line) continue;
    // serena-attach.js delivers its answer as additionalContext, which lands
    // in a `user` record, not a tool_result — so it is counted BEFORE the
    // `"tool_"` prefilter below, which would drop it. This is the numerator of
    // the pre-registered outcome metric for that hook: attachments delivered,
    // against nav.rg definition lookups. Matched on the hook's fixed phrase,
    // not its name, because the name never reaches the transcript.
    // Matched on the raw JSON line, where the quote is escaped (`\"`), so the
    // marker stops before it. `serena find_symbol(` is what the hook writes and
    // nothing else on this machine does.
    if (line.indexOf('serena find_symbol(') !== -1) nav.serena_attached++;
    if (line.indexOf('"tool_') === -1) continue;
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
        if (n.indexOf('mcp__semantica__') === 0) nav.semantica++;
        if (n === 'Skill' && (inp.skill || '') === 'karpathy-guidelines') skills.karpathy++;
        // ponytail ships six skills (ponytail, ponytail-review, -audit, -debt,
        // -gain, -help), plugin-scoped as `ponytail:<name>`. Any of them is an
        // explicit opt-in on top of the always-on hook injection.
        if (n === 'Skill' && /^(ponytail:)?ponytail(-[a-z]+)?$/.test(inp.skill || '')) skills.ponytail++;
        if (n.indexOf('lsp_') !== -1) nav.lsp++;
        if (n.indexOf('ast_grep') !== -1) nav.ast_grep++;
        if (n === 'Read') {
          const fp = inp.file_path || '';
          if (inp.offset || inp.limit) reads.ranged++; else reads.full++;
          if (seenRead.has(fp)) reads.dup++; else seenRead.add(fp);
        }
        let cmd = '';
        if (n === 'Bash') {
          cmd = inp.command || '';
          if (RG.test(cmd)) nav.rg++;
          if (OCR.test(cmd)) nav.ocr++;
          if (cmd.indexOf('graphify') !== -1) nav.graphify++;
          if (cmd.indexOf('텍스트검색:') !== -1) gate.escape++;
        }
        trace.push({ use: n, cmd: cmd });
      } else if (c.type === 'tool_result') {
        const n = idName.get(c.tool_use_id) || '';
        const body = typeof c.content === 'string' ? c.content : JSON.stringify(c.content || '');
        if (body.indexOf('[탐색 게이트]') !== -1) { gate.denied++; trace.push({ deny: true }); }
        if (c.is_error) {
          if (n === 'Bash') fail.bash++;
          else if (n === 'Edit' || n === 'Write' || n === 'NotebookEdit') fail.edit++;
          else if (n.indexOf('mcp__serena__') === 0) nav.serena_err++;
        }
      }
    }
  }

  // What each denial actually resolved to. Bookkeeping calls are stepped over:
  // ToolSearch in particular is how a deferred symbol tool gets loaded, so
  // stopping there would score the one path the gate is trying to produce as
  // "did something else".
  const SKIP = { ToolSearch: 1, TaskCreate: 1, TaskUpdate: 1, TaskGet: 1, TaskList: 1 };
  for (let i = 0; i < trace.length; i++) {
    if (!trace[i].deny) continue;
    let done = false;
    for (let j = i + 1; j < trace.length && j <= i + 12 && !done; j++) {
      const ev = trace[j];
      if (!ev.use || SKIP[ev.use]) continue;
      done = true;
      if (ev.use.indexOf('mcp__serena__') === 0 || ev.use.indexOf('lsp_') !== -1
          || ev.use.indexOf('ast_grep') !== -1) gate.to_serena++;
      else if (ev.cmd && ev.cmd.indexOf('텍스트검색:') !== -1) gate.to_escape++;
      else if (ev.use === 'Bash' && RG.test(ev.cmd)) gate.to_rg++;
      else if (ev.use === 'Read') gate.to_read++;
      else gate.to_other++;
    }
    if (!done) gate.to_other++;
  }
  return { nav, gate, fail, reads, skills, calls: Object.values(tools).reduce((a, b) => a + b, 0) };
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
