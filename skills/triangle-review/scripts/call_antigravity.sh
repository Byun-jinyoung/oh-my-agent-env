#!/usr/bin/env bash
# call_antigravity.sh — Direct Antigravity CLI (agy) spawn for Triangle Review.
#
# Replaces the previous call_gemini.sh after Gemini CLI deprecation (2026-06-18).
# Antigravity CLI serves the same role: a third independent peer reviewer that
# returns a JSON findings object. Tool approvals are auto-granted via
# --dangerously-skip-permissions so non-interactive use can reach the plugins
# / MCP servers that agy has imported (typically inherited from gemini-cli via
# `agy plugin import gemini-cli`).
#
# Usage:
#   call_antigravity.sh <prompt_file> <cwd> <output_json_file>
#
# Writes raw stdout to <output_json_file>.raw and extracts the final JSON
# object to <output_json_file>.

set -euo pipefail

PROMPT_FILE="${1:?prompt file required}"
CWD="${2:?cwd required}"
OUT="${3:?output path required}"

if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
    exit 2
fi
if [[ ! -d "$CWD" ]]; then
    echo "ERROR: cwd not a directory: $CWD" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT")"
RAW="$OUT.raw"

# -p (alias for --print) runs a single prompt non-interactively.
# --dangerously-skip-permissions auto-approves tool requests so agy can
# exercise its registered plugins / MCP servers without the interactive
# review gate. --print-timeout extends the 5m default for long reviews.
(
    cd "$CWD"
    agy \
        -p "$(cat "$PROMPT_FILE")" \
        --dangerously-skip-permissions \
        --print-timeout 30m
) > "$RAW" 2>&1

# Extract the largest balanced JSON object from the raw output.
# agy may prepend authentication / setup logs; we want the JSON body.
python3 - "$RAW" "$OUT" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
best = None
depth = 0
start = None
for i, ch in enumerate(raw):
    if ch == '{':
        if depth == 0:
            start = i
        depth += 1
    elif ch == '}':
        if depth > 0:
            depth -= 1
            if depth == 0 and start is not None:
                candidate = raw[start:i+1]
                try:
                    json.loads(candidate)
                    best = candidate
                except json.JSONDecodeError:
                    pass
if best is None:
    sys.stderr.write("ERROR: no valid JSON object in antigravity output\n")
    sys.exit(3)
open(sys.argv[2], 'w').write(best)
PY

echo "wrote $OUT"
