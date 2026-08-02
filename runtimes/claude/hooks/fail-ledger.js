#!/usr/bin/env node
// PostToolUseFailure hook: `oma-lab fail` has been able to remember broken
// commands across sessions since it was written, and nothing ever called it.
// Its only automatic caller is ledger.sh:215, which fires for commands run
// under `oma-lab run --`; every other failed command was remembered only if
// the model volunteered to type `oma-lab fail record`, which mid-failure-loop
// it does not. This hook is that call.
//
// Payload shape is NOT guessed — read out of the shipped CLI (2.1.220):
//   PostToolUseFailure { session_id, transcript_path, cwd, tool_name,
//                        tool_input, tool_use_id, error: string,
//                        is_interrupt?: boolean, duration_ms?: number }
// Two consequences worth stating, because the obvious implementation gets both
// wrong:
//   - There is no exit code anywhere in the payload. `tool_response` exists on
//     PostToolUse (the SUCCESS event) only. So this records the failure without
//     claiming to know how it exited, and filters interrupts with the
//     `is_interrupt` flag rather than by guessing at 130/141/143.
//   - Bare stdout from this event is transcript-only ("Exit code 0 - stdout
//     shown in transcript mode"). Text printed here would never reach the
//     model. Delivery is hookSpecificOutput.additionalContext, which the
//     settings schema accepts for PostToolUseFailure.
//
// Fail-open by construction: always exits 0, never blocks, and prints nothing
// unless the ledger has something to say about this exact command.
// OMA_FAIL_LEDGER_HOOK=0 disables it.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const OFF = new Set(['0', 'false', 'no', 'off']);
const CHILD_TIMEOUT_MS = 5000;
// Recording the ledger's own commands would poison it: `oma-lab fail check`
// exits 3 by design when a command is known-broken, and that nonzero exit is
// itself a Bash failure. Left unfiltered, the ledger records its own refusals
// and then refuses those.
const SELF = /\boma-lab\s+fail\b|\blab\/fail\.sh\b/;

function done(context) {
  if (context) {
    process.stdout.write(JSON.stringify({
      suppressOutput: true,
      hookSpecificOutput: {
        hookEventName: 'PostToolUseFailure',
        additionalContext: context,
      },
    }));
  }
  process.exit(0);
}

function run(file, args, opts) {
  // Returns {status, stdout, stderr} and never throws: a nonzero exit is the
  // signal here (check exits 3 on a known failure), not an error.
  try {
    const out = execFileSync(file, args, {
      encoding: 'utf8', timeout: CHILD_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'pipe'], ...opts,
    });
    return { status: 0, stdout: out, stderr: '' };
  } catch (e) {
    return {
      status: typeof e.status === 'number' ? e.status : -1,
      stdout: typeof e.stdout === 'string' ? e.stdout : '',
      stderr: typeof e.stderr === 'string' ? e.stderr : '',
    };
  }
}

const stdinTimeout = setTimeout(() => process.exit(0), 5000);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (input += c));
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    if (OFF.has(String(process.env.OMA_FAIL_LEDGER_HOOK || '1').toLowerCase())) return done('');

    const p = JSON.parse(input || '{}');
    if (p.tool_name !== 'Bash') return done('');
    // An interrupted command failed because the user stopped it. Remembering
    // that as "this command is broken" would refuse a retry that was never
    // tried in the first place.
    if (p.is_interrupt === true) return done('');

    const cmd = ((p.tool_input || {}).command || '').replace(/\s+/g, ' ').trim().slice(0, 2000);
    if (!cmd || SELF.test(cmd)) return done('');

    // Resolve the harness through this file's real path, not $PATH: the hook
    // runs as a symlink in ~/.claude/hooks and must find the checkout it was
    // installed from, even in a shell whose PATH lacks ~/.local/bin.
    const repoRoot = path.resolve(fs.realpathSync(__filename), '../../../..');
    const omaLab = path.join(repoRoot, 'scripts', 'oma-lab');
    if (!fs.existsSync(omaLab)) return done('');

    const cwd = typeof p.cwd === 'string' && p.cwd ? p.cwd : process.cwd();
    const top = run('git', ['-C', cwd, 'rev-parse', '--show-toplevel']);
    const root = top.status === 0 ? top.stdout.trim() : cwd;
    // Only repos that already keep lab state get rows. A failed command in an
    // unrelated repo must not create .oma-lab/ as a hook side effect — the
    // user never asked that repo to be tracked.
    if (!root || !fs.existsSync(path.join(root, '.oma-lab'))) return done('');

    // Ask before recording, so the answer is about PRIOR failures rather than
    // the one being written now. check exits 3 when this exact command is an
    // unresolved failure in an unchanged tree, and warns on stderr when the
    // tree has changed since.
    const check = run('bash', [omaLab, 'fail', 'check', '--repo', root, '--cmd', cmd]);
    const known = check.stderr.trim();

    // The error string is the only description of the failure that exists here,
    // and `fail check` prints the note back on the next occurrence — so a
    // future warning says what broke, not just that something did.
    const note = String(p.error || '').replace(/\s+/g, ' ').trim().slice(0, 300);
    run('bash', [omaLab, 'fail', 'record', '--repo', root, '--cmd', cmd].concat(
      note ? ['--note', note] : []));

    return done(known);
  } catch (e) {
    // A hook that throws must not look like a tool that failed differently.
  }
  process.exit(0);
});
