#!/usr/bin/env node
// UserPromptSubmit hook: inject compressed core working rules every turn.
// Reads ~/.claude/rules-core.md so the rules can be edited without touching
// this script. Never breaks the prompt: on any error it exits 0 silently.
const fs = require('fs');
const os = require('os');
const path = require('path');

const stdinTimeout = setTimeout(() => process.exit(0), 5000);
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => (input += c));
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const rulesPath = path.join(os.homedir(), '.claude', 'rules-core.md');
    const rules = fs.readFileSync(rulesPath, 'utf8').trim();
    if (rules) {
      process.stdout.write(
        JSON.stringify({
          hookSpecificOutput: {
            hookEventName: 'UserPromptSubmit',
            additionalContext: rules,
          },
        })
      );
    }
  } catch (e) {
    // never break the prompt
  }
  process.exit(0);
});
