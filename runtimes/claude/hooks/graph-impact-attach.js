#!/usr/bin/env node
'use strict';

// PostToolUse(Edit|Write|MultiEdit|NotebookEdit): after the third distinct,
// repository-contained source destination in one assistant turn, query the
// existing Graphify graph and attach code-review-graph's brief worktree impact.
// The transcript, not prompt wording, is the authority for the boundary.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const OUT_DIR = process.env.OMA_UPTAKE_DIR || path.join(os.homedir(), '.claude', 'uptake');
const LEDGER = path.join(OUT_DIR, 'opportunity.jsonl');
const TOOL = 'graph-impact';
const SOURCE_EXTENSIONS = new Set([
  '.c', '.cc', '.cpp', '.cs', '.css', '.dart', '.ex', '.exs', '.fs', '.fsx', '.go', '.h', '.hpp',
  '.ipynb', '.java', '.js', '.jsx', '.kt', '.kts', '.lua', '.mjs', '.php', '.py', '.r', '.rb', '.rs', '.scala',
  '.sh', '.sql', '.swift', '.ts', '.tsx', '.vue', '.zsh',
]);
const EXCLUDED_PARTS = new Set([
  '.git', '.github', '.gitlab', '.idea', '.vscode', 'build', 'config', 'configs', 'configuration', 'coverage',
  'dist', 'docs', 'doc', 'documentation', 'generated', 'graphify-out', 'node_modules', 'out', 'target', 'vendor',
  'vendored',
]);
const COMMAND_TIMEOUT_MS = 20000;
const MAX_OUTPUT = 6000;
let eventId = null;
let sessionId = '-';
const startedAt = Date.now();

function record(recordType, extra) {
  try {
    fs.mkdirSync(OUT_DIR, { recursive: true });
    fs.appendFileSync(LEDGER, JSON.stringify(Object.assign({
      schema_version: 1,
      record_type: recordType,
      ts: new Date().toISOString(),
      tool: TOOL,
      event_id: eventId,
      session_id: sessionId,
    }, extra || {})) + '\n');
  } catch (e) { /* observational output must not block edits */ }
}

function terminal(outcome, stages, extra) {
  record('attempt_terminal', Object.assign({
    outcome: outcome,
    latency_ms: Date.now() - startedAt,
    stages: stages,
  }, extra || {}));
  process.exit(0);
}

function gitRoot(cwd) {
  try {
    const result = spawnSync('git', ['-C', cwd, 'rev-parse', '--show-toplevel'], {
      encoding: 'utf8', timeout: 3000, maxBuffer: 4096,
    });
    if (result.status !== 0) return null;
    const root = (result.stdout || '').trim();
    return root && fs.existsSync(root) ? fs.realpathSync(root) : null;
  } catch (e) { return null; }
}

function executable(name) {
  const entries = (process.env.PATH || '').split(path.delimiter);
  for (const entry of entries) {
    const candidate = path.join(entry || '.', name);
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch (e) { /* next PATH entry */ }
  }
  return null;
}

function isGenuineUserPrompt(row) {
  if (!row || row.type !== 'user' || row.isMeta === true) return false;
  const content = row.message && row.message.content;
  if (typeof content === 'string') return content.trim().length > 0;
  return Array.isArray(content) && content.some((block) => block && block.type === 'text'
    && typeof block.text === 'string' && block.text.trim().length > 0);
}

function canonicalDestination(raw, root) {
  if (typeof raw !== 'string' || !raw) return null;
  const candidate = path.resolve(root, raw);
  let probe = candidate;
  const suffix = [];
  while (!fs.existsSync(probe)) {
    const parent = path.dirname(probe);
    if (parent === probe) return null;
    suffix.unshift(path.basename(probe));
    probe = parent;
  }
  let canonical;
  try { canonical = path.join(fs.realpathSync(probe), ...suffix); } catch (e) { return null; }
  const relative = path.relative(root, canonical);
  if (!relative || relative === '..' || relative.startsWith('..' + path.sep) || path.isAbsolute(relative)) return null;
  const parts = relative.split(path.sep);
  if (parts.some((part) => EXCLUDED_PARTS.has(part.toLowerCase()))) return null;
  const ext = path.extname(canonical).toLowerCase();
  return SOURCE_EXTENSIONS.has(ext) ? canonical : null;
}

function currentTurnSourceDestinations(transcriptPath, root, currentEventId) {
  let lines;
  try { lines = fs.readFileSync(transcriptPath, 'utf8').split('\n'); } catch (e) { return null; }
  let turnStart = 0;
  for (let i = 0; i < lines.length; i++) {
    try {
      const row = JSON.parse(lines[i]);
      if (isGenuineUserPrompt(row)) turnStart = i + 1;
    } catch (e) { /* malformed transcript lines are not evidence */ }
  }
  const destinations = new Set();
  const failedEdits = new Set();
  for (let i = turnStart; i < lines.length; i++) {
    let row;
    try { row = JSON.parse(lines[i]); } catch (e) { continue; }
    const content = row && row.message && row.message.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (block && block.type === 'tool_result' && block.is_error === true
          && typeof block.tool_use_id === 'string') failedEdits.add(block.tool_use_id);
    }
  }
  let currentCount = null;
  let currentIsSource = false;
  let lastSourceCount = null;
  let lastSourceAdded = false;
  for (let i = turnStart; i < lines.length; i++) {
    let row;
    try { row = JSON.parse(lines[i]); } catch (e) { continue; }
    if (!row || row.type !== 'assistant') continue;
    const content = row.message && row.message.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (!block || block.type !== 'tool_use' || typeof block.id !== 'string' || !block.id
          || !['Edit', 'Write', 'MultiEdit', 'NotebookEdit'].includes(block.name)) continue;
      if (failedEdits.has(block.id)) continue;
      const input = block.input || {};
      const destination = canonicalDestination(input.file_path || input.notebook_path || input.path, root);
      const before = destinations.size;
      if (destination) destinations.add(destination);
      if (destination) {
        lastSourceCount = destinations.size;
        lastSourceAdded = destinations.size > before;
      }
      if (block.id === currentEventId) {
        currentCount = destinations.size;
        currentIsSource = Boolean(destination);
      }
    }
  }
  // A missing PostToolUse ID must be observable as a terminal opportunity, not
  // silently repaired from a transcript ID. The last source edit is the only
  // event the runtime could have just completed; its ID remains deliberately
  // unused in the ledger.
  if (currentEventId === null && lastSourceCount === 3 && lastSourceAdded) {
    currentCount = lastSourceCount;
    currentIsSource = true;
  }
  return {
    count: currentCount,
    currentIsSource: currentIsSource,
    destinations: Array.from(destinations),
  };
}

function run(command, args) {
  return new Promise((resolve) => {
    const began = Date.now();
    let child;
    try {
      child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      resolve({ outcome: 'spawn_error', latency_ms: Date.now() - began });
      return;
    }
    let output = '';
    let settled = false;
    let timer;
    const collect = (chunk) => {
      if (output.length < MAX_OUTPUT) output += chunk.toString('utf8').slice(0, MAX_OUTPUT - output.length);
    };
    child.stdout.on('data', collect);
    child.stderr.on('data', collect);
    const finish = (outcome) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ outcome: outcome, latency_ms: Date.now() - began, output: output.trim() });
    };
    child.on('error', () => finish('spawn_error'));
    child.on('close', (code) => finish(code === 0 ? 'ok' : 'failed'));
    timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch (e) { /* process already exited */ }
      finish('timeout');
    }, COMMAND_TIMEOUT_MS);
  });
}

function brief(text, limit) {
  return text.replace(/\r/g, '').trim().slice(0, limit || 1800);
}

const stdinTimeout = setTimeout(() => process.exit(0), 5000);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', async () => {
  clearTimeout(stdinTimeout);
  let payload;
  try { payload = JSON.parse(input || '{}'); } catch (e) { return process.exit(0); }
  if (!payload || !['Edit', 'Write', 'MultiEdit', 'NotebookEdit'].includes(payload.tool_name)) return process.exit(0);
  sessionId = typeof payload.session_id === 'string' && payload.session_id ? payload.session_id : '-';
  const cwd = payload.cwd || process.cwd();
  const root = gitRoot(cwd);
  let scanRoot;
  try { scanRoot = root || fs.realpathSync(cwd); } catch (e) { return process.exit(0); }
  if (typeof payload.transcript_path !== 'string' || !fs.existsSync(payload.transcript_path)) return process.exit(0);
  eventId = typeof payload.tool_use_id === 'string' && payload.tool_use_id ? payload.tool_use_id : null;
  const currentTurn = currentTurnSourceDestinations(payload.transcript_path, scanRoot, eventId);
  if (!currentTurn || !currentTurn.currentIsSource || currentTurn.count !== 3) return process.exit(0);

  const prerequisiteStages = [];
  if (!root) prerequisiteStages.push({ stage: 'git_worktree_root', outcome: 'missing', latency_ms: 0 });
  if (!eventId) {
    prerequisiteStages.push({ stage: 'tool_use_id', outcome: 'missing', latency_ms: 0 });
    record('opportunity', { outcome: 'missing_tool_use_id', source_files: 3 });
    return terminal('missing_tool_use_id', prerequisiteStages);
  }
  if (!root) {
    record('opportunity', { outcome: 'git_worktree_root_missing', source_files: 3 });
    return terminal('git_worktree_root_missing', prerequisiteStages);
  }
  const graph = path.join(root, 'graphify-out', 'graph.json');
  if (!fs.existsSync(graph)) prerequisiteStages.push({ stage: 'graphify_graph', outcome: 'missing', latency_ms: 0 });
  const graphify = executable('graphify');
  if (!graphify) prerequisiteStages.push({ stage: 'graphify', outcome: 'missing', latency_ms: 0 });
  const reviewGraph = executable('code-review-graph');
  if (!reviewGraph) prerequisiteStages.push({ stage: 'code_review_graph', outcome: 'missing', latency_ms: 0 });
  if (prerequisiteStages.length) {
    const outcome = prerequisiteStages.map((stage) => stage.stage + '_missing').join('_and_');
    record('opportunity', { outcome: outcome, source_files: 3 });
    return terminal(outcome, prerequisiteStages);
  }

  record('opportunity', { outcome: 'eligible', source_files: 3 });
  record('attempt_started', { outcome: 'started', source_files: 3 });
  const stages = [];
  const relativeFiles = currentTurn.destinations.map((file) => path.relative(root, file));
  // Graphify's lexical start-node selector is easily distracted by prose
  // ("changed files" selected testCommand/lintCommand in the real E2E).
  // Exact repo-relative paths select the three file nodes deterministically.
  const question = relativeFiles.join(' ');
  let stage = await run(graphify, ['query', question, '--budget', '800', '--graph', graph]);
  stages.push(Object.assign({ stage: 'graphify_query' }, stage));
  if (stage.outcome !== 'ok') return terminal('graphify_query_' + stage.outcome, stages);
  const dependencies = brief(stage.output);
  if (!dependencies) return terminal('graphify_query_empty', stages);
  stage = await run(reviewGraph, ['detect-changes', '--base', 'HEAD', '--brief', '--repo', root]);
  stages.push(Object.assign({ stage: 'code_review_graph_detect_changes' }, stage));
  if (stage.outcome !== 'ok') return terminal('code_review_graph_detect_changes_' + stage.outcome, stages);
  const impact = brief(stage.output);
  if (!impact) return terminal('code_review_graph_detect_changes_empty', stages);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PostToolUse',
      additionalContext:
        'Graph impact for the third source edit:\n'
        + 'Graphify dependency context (current graph):\n' + dependencies + '\n'
        + 'CRG impact (all uncommitted worktree changes):\n' + impact
        + '\n<!-- oma-graph-impact-event:' + eventId + ' -->',
    },
  }));
  return terminal('attached', stages, {
    dependency_chars: dependencies.length,
    impact_chars: impact.length,
  });
});
