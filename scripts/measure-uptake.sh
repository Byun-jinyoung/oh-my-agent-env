#!/usr/bin/env bash
# Where should a rule live? Measure, do not guess.
#
# This harness carries rules in three places, and they are not interchangeable:
#
#   resident   ~/.claude/CLAUDE.md   (rules/*.md + tools.md, assembled by sync)
#   per-turn   rules-core.md         (UserPromptSubmit hook, every prompt)
#   on-demand  skills/               (loaded only if something calls Skill)
#
# The tempting move is to shrink the resident file by pushing rules into skills.
# That is only sound if skills actually get loaded. This script answers that from
# transcripts instead of intuition — the same reason rules/70-analysis.md exists.
#
#   scripts/measure-uptake.sh            # ~/.claude/projects
#   scripts/measure-uptake.sh <dir>      # any transcript root
#
# Reads only; prints aggregates. Transcript bodies never reach a terminal.
set -uo pipefail

ROOT="${1:-$HOME/.claude/projects}"
[ -d "$ROOT" ] || { echo "no transcript root: $ROOT" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

python3 - "$ROOT" <<'PYEOF'
import collections, glob, json, os, sys

root = sys.argv[1]
# Recursive: transcripts are not all one level down. A `*/*.jsonl` glob found
# 62 tool-using sessions where `grep -rl` found 179 — a third of the corpus,
# silently missing.
files = glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True)

TODO = {"TaskCreate", "TaskUpdate", "TodoWrite"}
INJECT_MARK = "## 작업 핵심 규칙"

sessions = set()
tool_sessions = set()
skill_sessions = set()
todo_sessions = set()
skills = collections.Counter()
tools = collections.Counter()
inject_records = collections.Counter()   # per session

for path in files:
    sid = os.path.basename(path)
    seen_uuid = set()
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        continue
    with fh:
        for line in fh:
            # Most .jsonl files next to a transcript are sidecars — `mode`,
            # `permission-mode`, `last-prompt`. Counting them as sessions
            # buries the real denominator: 62 conversations looked like 62
            # out of 6,577 rather than 62 out of 78.
            if '"type":"user"' in line or '"type":"assistant"' in line:
                sessions.add(sid)
            if INJECT_MARK in line:
                try:
                    rec = json.loads(line)
                except ValueError:
                    rec = None
                if rec is not None:
                    u = rec.get("uuid")
                    if u not in seen_uuid:
                        seen_uuid.add(u)
                        inject_records[sid] += 1
            if '"tool_use"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            for c in (rec.get("message") or {}).get("content") or []:
                if not isinstance(c, dict) or c.get("type") != "tool_use":
                    continue
                name = c.get("name") or "?"
                tools[name] += 1
                tool_sessions.add(sid)
                if name == "Skill":
                    skills[(c.get("input") or {}).get("skill", "?")] += 1
                    skill_sessions.add(sid)
                elif name in TODO:
                    todo_sessions.add(sid)

n = max(1, len(tool_sessions))
pct = lambda k: f"{100 * k / n:.0f}%"

print(f"transcript root      : {root}")
print(f"conversations        : {len(sessions)}  ({len(files)} .jsonl incl. sidecars)")
print(f"with tool use        : {len(tool_sessions)}")
print(f"tool calls           : {sum(tools.values())}")
print()
print("-- on-demand: does anything actually load a skill? --")
print(f"Skill calls          : {sum(skills.values())} in {len(skill_sessions)} sessions ({pct(len(skill_sessions))})")
for name, count in skills.most_common(10):
    print(f"    {name:34s} {count}")
if not skills:
    print("    (none)")
print()
print("-- for contrast: a rule that has a hook behind it --")
print(f"ToDo-tool sessions   : {len(todo_sessions)} ({pct(len(todo_sessions))})")
print()
print("-- per-turn channel: what the UserPromptSubmit hook costs --")
total_inject = sum(inject_records.values())
worst = inject_records.most_common(1)
print(f"rule injections      : {total_inject} across {len(inject_records)} sessions")
if worst:
    sid, count = worst[0]
    print(f"worst session        : {count} injections ({sid[:8]}…)")
print("bytes per injection  : wc -c runtimes/claude/rules-core.md")
print()
print("Reading: a low Skill rate means a rule moved out of the resident file")
print("stops being applied. Compare against the ToDo rate, which is enforced by")
print("a Stop hook rather than by prose.")
PYEOF
