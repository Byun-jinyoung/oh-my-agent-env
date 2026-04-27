#!/usr/bin/env bash
# call_gemini.sh — Direct Gemini CLI spawn for Triangle Review.
#
# Rationale: gemini-mcp wrapper spawns `gemini --prompt ... --model ...` WITHOUT
# --yolo / --allowed-mcp-server-names, so non-interactive approval gate strips
# external MCP tools from the LLM's tool_declarations. Empirically verified:
# wrapper call → serena_failed:tool_not_found_in_tool_declarations;
# direct spawn with yolo+allowlist → 60+ MCP tools available.
#
# Usage:
#   call_gemini.sh <prompt_file> <cwd> <output_json_file>
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

# -p is positional prompt flag; --yolo auto-approves all tool calls;
# --allowed-mcp-server-names lists servers whose tools should be exposed.
# Extend the allowlist as new MCP servers are shared to Gemini.
(
    cd "$CWD"
    gemini \
        --yolo \
        --allowed-mcp-server-names serena \
        --allowed-mcp-server-names code-review-graph \
        -p "$(cat "$PROMPT_FILE")"
) > "$RAW" 2>&1

# Extract the last balanced JSON object from the raw output.
# Gemini may prepend warnings or emit trailing logs; we want the JSON body.
python3 - "$RAW" "$OUT" <<'PY'
import json, re, sys
raw = open(sys.argv[1]).read()
# Find the largest balanced {...} block by scanning backwards.
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
    sys.stderr.write("ERROR: no valid JSON object in gemini output\n")
    sys.exit(3)
open(sys.argv[2], 'w').write(best)
PY

echo "wrote $OUT"
