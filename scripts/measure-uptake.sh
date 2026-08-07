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
#   scripts/measure-uptake.sh trend      # read the per-session rows instead
#
# Reads only; prints aggregates. Transcript bodies never reach a terminal.
set -uo pipefail

# `trend` reads what the SessionEnd hook appends, and rescans nothing. The full
# scan below is the reason that hook exists: 30-60s over 8809 files runs only
# when someone remembers, and a measurement that must be remembered cannot tell
# you whether a change that removes remembering worked.
if [ "${1:-}" = "trend" ]; then
  ROWS="${OMA_UPTAKE_DIR:-$HOME/.claude/uptake}/rows.jsonl"
  [ -f "$ROWS" ] || { echo "no rows yet: $ROWS (the SessionEnd hook writes one per session)" >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
  python3 - "$ROWS" <<'PYEOF'
import json, sys

rows = []
for line in open(sys.argv[1], errors="ignore"):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except ValueError:
        continue
if not rows:
    print("rows file has no readable rows")
    raise SystemExit(1)

def rate(key, sub):
    n = sum(1 for r in rows if (r.get(key) or {}).get(sub, 0) > 0)
    return n, 100.0 * n / len(rows)

print("per-session rows : %d  (%s .. %s)" % (len(rows), rows[0].get("ts", "?")[:10], rows[-1].get("ts", "?")[:10]))
print("total tool calls : %d" % sum(r.get("calls", 0) for r in rows))
print()
print("-- navigation: which channel answers 'where is this code' --")
print("  %-12s %8s %8s %10s" % ("channel", "sessions", "rate", "calls"))
for sub, label in (("rg", "rg/grep"), ("serena", "serena"), ("lsp", "lsp_*"),
                   ("ast_grep", "ast_grep"), ("graphify", "graphify"), ("toolsearch", "ToolSearch")):
    n, pct = rate("nav", sub)
    print("  %-12s %8d %7.1f%% %10d" % (label, n, pct, sum((r.get("nav") or {}).get(sub, 0) for r in rows)))
print()
print("-- symbol-search-gate: did it move serena, and does it misfire? --")
d = sum((r.get("gate") or {}).get("denied", 0) for r in rows)
e = sum((r.get("gate") or {}).get("escape", 0) for r in rows)
print("  denials              : %d" % d)
print("  텍스트검색: escapes  : %d" % e)
if d + e:
    print("  escape share         : %.1f%%  <- high means the gate fires on searches it should not" % (100.0 * e / (d + e)))
print("  baseline before the gate: serena in 2 of 220 sessions (0.9%)")
print()
print("-- reads --")
for sub in ("full", "ranged", "dup"):
    print("  %-8s %6d" % (sub, sum((r.get("reads") or {}).get(sub, 0) for r in rows)))
raise SystemExit(0)
PYEOF
  # Without this the script falls through and treats "trend" as a transcript
  # root. `fi` ends the branch, not the script.
  exit $?
fi

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
skill_user_initiated = 0
skill_autonomous = 0
autonomous_examples = []
last_user = ""

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
            if '"type":"user"' in line and '"tool_use"' not in line:
                # Remember what the user last said, so a Skill call can be
                # attributed. Cross-review was right that "every call was a
                # slash command" is an inference from the skill names unless
                # something actually checks the prompt that preceded it.
                try:
                    rec = json.loads(line)
                except ValueError:
                    rec = None
                if rec is not None and rec.get("type") == "user":
                    content = (rec.get("message") or {}).get("content")
                    if isinstance(content, str):
                        last_user = content
                    elif isinstance(content, list):
                        last_user = " ".join(
                            b.get("text", "") for b in content
                            if isinstance(b, dict) and b.get("type") == "text")
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
                    sk = (c.get("input") or {}).get("skill", "?")
                    skills[sk] += 1
                    skill_sessions.add(sid)
                    # A slash invocation names the skill in the prompt itself.
                    # Absent that, the model reached for it on its own — the
                    # only case that matters for "can a rule live in a skill".
                    leaf = sk.split(":")[-1]
                    if leaf and ("/" + leaf) in last_user:
                        skill_user_initiated += 1
                    else:
                        skill_autonomous += 1
                        autonomous_examples.append(f"{sk} ({sid[:8]})")
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
print(f"  user-invoked (slash) : {skill_user_initiated}")
print(f"  model-initiated      : {skill_autonomous}")
for ex in autonomous_examples[:5]:
    print(f"      {ex}")
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
print("Reading: what decides whether a rule can live in a skill is the")
print("model-initiated count, not the total — a slash invocation says the user")
print("knew the skill existed, not that the harness would have reached it.")
print()
print("Confound this does NOT control for: a session where no skill was")
print("relevant produces the same zero as one where a relevant skill was")
print("ignored. To separate them you would have to label sessions by whether a")
print("skill applied, and measure the rate only within that subset.")
PYEOF
