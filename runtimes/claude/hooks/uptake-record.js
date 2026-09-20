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
const ATTEMPTS = path.join(OUT_DIR, 'attach.jsonl');
const GRAPH_IMPACTS = path.join(OUT_DIR, 'opportunity.jsonl');
const DELIVERIES = path.join(OUT_DIR, 'delivery.jsonl');
const SCHEMA_VERSION = 1;

function findTranscript(sessionId) {
  if (!sessionId || sessionId === '-' || !fs.existsSync(PROJECTS)) return null;
  for (const d of fs.readdirSync(PROJECTS)) {
    const p = path.join(PROJECTS, d, sessionId + '.jsonl');
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function attemptIndex(ledger, sessionId, tool) {
  const indexed = new Map();
  try {
    for (const line of fs.readFileSync(ledger, 'utf8').split('\n')) {
      if (!line) continue;
      let row;
      try { row = JSON.parse(line); } catch (e) { continue; }
      if (row.schema_version !== SCHEMA_VERSION || row.session_id !== sessionId
          || typeof row.event_id !== 'string' || !row.event_id) continue;
      if (tool && row.tool !== tool) continue;
      const key = row.event_id;
      const state = indexed.get(key) || { opportunity: 0, started: 0, terminal: [] };
      if (row.record_type === 'opportunity') state.opportunity++;
      else if (row.record_type === 'attempt_started') state.started++;
      else if (row.record_type === 'attempt_terminal') state.terminal.push(row.outcome);
      indexed.set(key, state);
    }
  } catch (e) { /* no attempt ledger makes every delivery orphaned */ }
  return indexed;
}

function appendObservations(rows) {
  if (!rows.length) return;
  const keyFor = (row) => [
    row.session_id, row.tool || '', row.record_type, row.event_id || '', row.join_index || 0,
    row.record_type === 'consumption' ? row.outcome || '' : '',
  ].join('\0');
  const seen = new Set();
  try {
    for (const line of fs.readFileSync(DELIVERIES, 'utf8').split('\n')) {
      let row;
      try { row = JSON.parse(line); } catch (e) { continue; }
      seen.add(keyFor(row));
    }
  } catch (e) { /* first write */ }
  try {
    fs.mkdirSync(OUT_DIR, { recursive: true });
    for (const row of rows) {
      const key = keyFor(row);
      if (seen.has(key)) continue;
      seen.add(key);
      fs.appendFileSync(DELIVERIES, JSON.stringify(row) + '\n');
    }
  } catch (e) { /* observational output must not break SessionEnd */ }
}

function scan(file, sessionId) {
  // ocr / semantica added 2026-08-16 with the tools themselves (sync installs
  // them; see lib/sync/external-tools.sh). The 2026-08-07 survey predicted
  // 0-5% uptake for anything the model must choose to call; these are the
  // numbers that check that prediction. Present at 0 from day one so a row
  // that carries the key at 0 means "installed and unused", and a row without
  // the key means "predates the counter" — the consumer renders only rows
  // that carry it.
  const nav = { rg: 0, serena: 0, serena_err: 0, lsp: 0, ast_grep: 0, graphify: 0, toolsearch: 0,
                ocr: 0, semantica: 0 };
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
  const attachments = [];
  const graphAttachments = [];

  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line) continue;
    // Only a typed async-hook attachment is delivery evidence. The comment is
    // the PostToolUse tool_use_id, not a content-derived correlation guess.
    if (line.indexOf('async_hook_response') !== -1) {
      let rec = null;
      try { rec = JSON.parse(line); } catch (e) { rec = null; }
      const att = rec && rec.attachment;
      const ctx = att && att.type === 'async_hook_response' && att.response
        && att.response.hookSpecificOutput && att.response.hookSpecificOutput.additionalContext;
      if (typeof ctx === 'string' && ctx.indexOf('serena find_symbol(') === 0) {
        const named = [];
        const P = /([A-Za-z0-9_./-]+\.[A-Za-z0-9_]+):(\d+)-(\d+)/g;
        let mm;
        while ((mm = P.exec(ctx)) !== null) named.push(mm[1]);
        const ids = [];
        const ID = /<!-- oma-serena-event:([^<>\s]+) -->/g;
        while ((mm = ID.exec(ctx)) !== null) ids.push(mm[1]);
        attachments.push({ ids: ids, names: named, at: trace.length });
      } else if (typeof ctx === 'string'
          && ctx.indexOf('Graph impact for the third source edit:\n') === 0) {
        const ids = [];
        const ID = /<!-- oma-graph-impact-event:([^<>\s]+) -->/g;
        let mm;
        while ((mm = ID.exec(ctx)) !== null) ids.push(mm[1]);
        graphAttachments.push({ ids: ids });
      }
    }
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
        const file = inp.file_path || inp.path || '';
        if (n === 'Bash') {
          cmd = inp.command || '';
          if (RG.test(cmd)) nav.rg++;
          if (OCR.test(cmd)) nav.ocr++;
          if (cmd.indexOf('graphify') !== -1) nav.graphify++;
          if (cmd.indexOf('텍스트검색:') !== -1) gate.escape++;
        }
        trace.push({ use: n, cmd: cmd, file: file, tool_use_id: c.id });
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

  const attempts = attemptIndex(ATTEMPTS, sessionId, null);
  const joins = [];
  const delivered = new Set();
  for (let index = 0; index < attachments.length; index++) {
    const attachment = attachments[index];
    const base = {
      schema_version: SCHEMA_VERSION, ts: new Date().toISOString(), session_id: sessionId,
      event_id: null, initiation: 'model', mode: 'unknown', delivery_eligible: 'unknown',
      join_index: index + 1, tool: 'serena-attach',
    };
    if (attachment.ids.length !== 1) {
      joins.push(Object.assign({}, base, { record_type: 'invalid_join', outcome: 'missing_or_ambiguous_event_id' }));
      continue;
    }
    const eventId = attachment.ids[0];
    base.event_id = eventId;
    if (delivered.has(eventId)) {
      joins.push(Object.assign({}, base, { record_type: 'duplicate_join', outcome: 'duplicate_event_id' }));
      continue;
    }
    delivered.add(eventId);
    const attempt = attempts.get(eventId);
    if (!attempt) {
      joins.push(Object.assign({}, base, { record_type: 'orphan_delivery', outcome: 'no_matching_attempt' }));
      continue;
    }
    if (attempt.opportunity > 1 || attempt.started > 1 || attempt.terminal.length > 1) {
      joins.push(Object.assign({}, base, { record_type: 'duplicate_join', outcome: 'duplicate_attempt_id' }));
      continue;
    }
    if (attempt.opportunity !== 1 || attempt.started !== 1 || attempt.terminal.length !== 1
        || attempt.terminal[0] !== 'attached') {
      joins.push(Object.assign({}, base, { record_type: 'invalid_join', outcome: 'invalid_attempt_lifecycle' }));
      continue;
    }
    joins.push(Object.assign({}, base, { record_type: 'delivery', outcome: 'delivered' }));
    let calls = 0;
    let matched = null;
    for (let i = attachment.at; i < trace.length && calls < 3; i++) {
      const ev = trace[i];
      if (!ev.use || SKIP[ev.use] || ev.tool_use_id === eventId) continue;
      calls++;
      const hay = (ev.file || '') + ' ' + (ev.cmd || '');
      const name = attachment.names.find((n) => n && hay.indexOf(n) !== -1);
      if (name) { matched = name; break; }
    }
    joins.push(Object.assign({}, base, {
      record_type: 'consumption',
      outcome: matched ? 'matched_named_path' : (calls === 3 ? 'no_match_in_three_calls' : 'window_incomplete'),
      real_tool_calls: calls,
      matched_path: matched,
    }));
  }
  const graphAttempts = attemptIndex(GRAPH_IMPACTS, sessionId, 'graph-impact');
  const graphDelivered = new Set();
  for (let index = 0; index < graphAttachments.length; index++) {
    const attachment = graphAttachments[index];
    const base = {
      schema_version: SCHEMA_VERSION, ts: new Date().toISOString(), session_id: sessionId,
      event_id: null, initiation: 'model', mode: 'unknown', delivery_eligible: 'unknown',
      join_index: index + 1, tool: 'graph-impact',
    };
    if (attachment.ids.length !== 1) {
      joins.push(Object.assign({}, base, { record_type: 'invalid_join', outcome: 'missing_or_ambiguous_event_id' }));
      continue;
    }
    const eventId = attachment.ids[0];
    base.event_id = eventId;
    if (graphDelivered.has(eventId)) {
      joins.push(Object.assign({}, base, { record_type: 'duplicate_join', outcome: 'duplicate_event_id' }));
      continue;
    }
    graphDelivered.add(eventId);
    const attempt = graphAttempts.get(eventId);
    if (!attempt) {
      joins.push(Object.assign({}, base, { record_type: 'orphan_delivery', outcome: 'no_matching_attempt' }));
      continue;
    }
    if (attempt.opportunity !== 1 || attempt.started !== 1 || attempt.terminal.length !== 1
        || attempt.terminal[0] !== 'attached') {
      const duplicate = attempt.opportunity > 1 || attempt.started > 1 || attempt.terminal.length > 1;
      joins.push(Object.assign({}, base, {
        record_type: duplicate ? 'duplicate_join' : 'invalid_join',
        outcome: duplicate ? 'duplicate_attempt_id' : 'invalid_attempt_lifecycle',
      }));
      continue;
    }
    joins.push(Object.assign({}, base, { record_type: 'delivery', outcome: 'delivered' }));
  }
  return { nav, gate, fail, reads, skills, joins, calls: Object.values(tools).reduce((a, b) => a + b, 0) };
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
    const sessionId = typeof p.session_id === 'string' && p.session_id ? p.session_id : '-';
    const m = scan(file, sessionId);
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
    appendObservations(m.joins);
  } catch (e) {
    /* fail-open */
  }
  return process.exit(0);
});
