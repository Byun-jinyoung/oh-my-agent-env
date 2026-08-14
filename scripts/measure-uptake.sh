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
# scan below is the reason that hook exists — not because it is slow (measured
# 2026-08-14: 6.8s over 10,675 files; an earlier comment here claimed 30-60s
# over 8809 and was wrong on both numbers) but because it runs only when someone
# remembers, and a measurement that must be remembered cannot tell you whether a
# change that removes remembering worked.
if [ "${1:-}" = "trend" ]; then
  ROWS="${OMA_UPTAKE_DIR:-$HOME/.claude/uptake}/rows.jsonl"
  [ -f "$ROWS" ] || { echo "no rows yet: $ROWS (the SessionEnd hook writes one per session)" >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
  python3 - "$ROWS" <<'PYEOF'
import json, sys

raw = []
for line in open(sys.argv[1], errors="ignore"):
    line = line.strip()
    if not line:
        continue
    try:
        raw.append(json.loads(line))
    except ValueError:
        continue
if not raw:
    print("rows file has no readable rows")
    raise SystemExit(1)

# One row is one SessionEnd, NOT one session. uptake-record.js takes
# p.transcript_path and rescans that one file from the top every time
# (uptake-record.js:143-153 — no cursor, no delta), so a session that ends
# repeatedly (exit / clear / logout / prompt_input_exit / resume) leaves several
# cumulative snapshots of the same growing transcript. Summing them counted the
# same tool calls once per ending: measured on the real ledger, 72 rows over 50
# sessions with one session holding 10 of them, inflating rg by 217%, serena by
# 250%, graphify by 200% and ToolSearch by 181%. Those inflated totals were
# quoted as evidence in this investigation before anyone grouped by session.
#
# Collapse with an element-wise MAX rather than "take the last row". Every
# multi-row session measured was monotonic non-decreasing (0 of 6 with a falling
# counter), so on this data the two agree — but a transcript can lose records to
# compaction, and a later, shorter snapshot must not retract work already
# recorded. Max is also what keeps a counter that only later rows carry: absent
# is not zero, and a field added mid-window belongs to the session that has it.
def merge(dst, src):
    for k, v in src.items():
        if isinstance(v, dict):
            merge(dst.setdefault(k, {}), v)
        elif isinstance(v, bool) or not isinstance(v, (int, float)):
            dst[k] = v                      # ts / cwd / reason: latest wins
        else:
            dst[k] = max(dst.get(k, v), v)

sessions = {}
order = []
for r in sorted(raw, key=lambda x: x.get("ts", "")):
    sid = r.get("session", "-")
    if sid not in sessions:
        sessions[sid] = {}
        order.append(sid)
    merge(sessions[sid], r)
rows = [sessions[s] for s in order]

def rate(key, sub):
    n = sum(1 for r in rows if (r.get(key) or {}).get(sub, 0) > 0)
    return n, 100.0 * n / len(rows)

ts = sorted(r.get("ts", "?") for r in raw)
print("sessions         : %d  (from %d rows, %s .. %s)"
      % (len(rows), len(raw), ts[0][:10], ts[-1][:10]))
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
# Summing with .get(k, 0) over rows that have no `gate` key prints "denials: 0",
# which reads as "the gate ran and never fired" — the exact confusion between a
# key that is absent and a value that is zero that misdiagnosed the serena
# config twice (a project.yml carrying `language_servers:` and no `languages:`
# was read as "languages is empty"). Rows predating the counters, and rows from
# any machine where the hook is not installed, both land in that hole. So: count
# the rows that CARRY the key and render only from those.
gate_rows = [r for r in rows if isinstance(r.get("gate"), dict)]
if not gate_rows:
    print("  no data in window — no row here carries gate.* (not recorded; not zero firings)")
else:
    print("  rows carrying gate.*  : %d of %d in window" % (len(gate_rows), len(rows)))
    d = sum(r["gate"].get("denied", 0) for r in gate_rows)
    e = sum(r["gate"].get("escape", 0) for r in gate_rows)
    print("  denials              : %d" % d)
    # Over-counts on purpose-built greps: the producer matches any Bash command
    # containing the marker, so searching FOR the marker increments it. On this
    # machine it reads 587 against 77 denials. Use it as an upper bound; the
    # sunset below deliberately uses to_escape, which only counts the tool that
    # actually ran after a denial.
    print("  텍스트검색: escapes  : %d  (upper bound — see comment)" % e)
    print("  baseline before the gate: serena in 2 of 220 sessions (0.9%)")
    # A denial count says the gate fired, not that it worked. Measured over the
    # first 28 firings: 21% reached serena, 54% re-ran the same search with the
    # escape appended. Replaying the whole corpus explained that 54%: 56.7% of
    # what the gate fired on were alternations and prefix sweeps serena cannot
    # answer, so the escape was the only way forward. The narrowing that follows
    # from that (symbol-search-gate.js: isSingleSymbol) cuts firings 337 -> 123.
    outs = [("to_serena", "→ serena/lsp (성공)"), ("to_escape", "→ 탈출로 강행"),
            ("to_rg", "→ 다른 rg 재시도"), ("to_read", "→ Read 로 전환"),
            ("to_other", "→ 기타")]
    # Same key-absent-vs-zero split one level down: gate.to_* was added after
    # gate.denied, so early rows carry the outer key and not the inner ones.
    out_rows = [r for r in gate_rows if any(k in r["gate"] for k, _ in outs)]
    if not out_rows:
        print("  (outcome counters absent — rows predate the gate.to_* fields)")
    else:
        tot = sum(sum(r["gate"].get(k, 0) for r in out_rows) for k, _ in outs)
        print("  -- what each denial resolved to (%d rows) --" % len(out_rows))
        for k, label in outs:
            n = sum(r["gate"].get(k, 0) for r in out_rows)
            print("    %-22s %5d  (%s)" % (label, n, "%.0f%%" % (100.0 * n / tot) if tot else "-"))
        # SUNSET. Keeping this gate was argued for on one prediction: that
        # narrowing it to single-symbol lookups removes the misfires, and so the
        # escape share falls away from its 54% baseline. A prediction nobody
        # checks is how the gate reached 28 firings at 54% escape before anyone
        # noticed, so the check is computed here rather than promised in prose.
        #
        # Reported per FIRING, not per session: firings are the unit the 54%
        # was measured in, and one session can hold several.
        SUNSET_N, BASELINE = 20, 54.0
        esc = sum(r["gate"].get("to_escape", 0) for r in out_rows)
        share = 100.0 * esc / tot if tot else 0.0
        print("  -- sunset check (escape share vs the %.0f%% that motivated narrowing) --" % BASELINE)
        if tot < SUNSET_N:
            print("    %d/%d firings — undecided, and undecided is not a pass" % (tot, SUNSET_N))
        elif share >= BASELINE:
            print("    %.0f%% over %d firings: NOT BELOW BASELINE — narrowing did not work." % (share, tot))
            print("    The case for keeping the gate was this number falling. Retire it:")
            print("    hooks/manifest.json (move to `retired`), then delete the hook and its test.")
        else:
            print("    %.0f%% over %d firings (baseline %.0f%%) — narrowing is holding." % (share, tot, BASELINE))
# Same key-absent-vs-zero rule as the gate block above, and it was NOT applied
# here at first — the discipline was installed on gate.* only. What that cost,
# measured on the real ledger: 72 rows, 13 of them with serena calls, and zero
# of those 13 carrying serena_err (the counter landed later the same day). This
# line printed "serena calls that errored: 0 / 28 (0%)" while the transcripts
# behind those very calls showed 8 of them answering "No active project" and 2
# raising — a 100% failure rate rendered as a clean 0%. That number was then
# quoted as evidence serena was working.
err_rows = [r for r in rows if "serena_err" in (r.get("nav") or {})]
sc_all = sum((r.get("nav") or {}).get("serena", 0) for r in rows)
sc = sum((r.get("nav") or {}).get("serena", 0) for r in err_rows)
se = sum((r.get("nav") or {}).get("serena_err", 0) for r in err_rows)
if sc_all and not err_rows:
    print("  serena calls: %d, of which errored: not recorded"
          " (no row in window carries nav.serena_err — not a 0%% failure rate)" % sc_all)
elif sc:
    print("  serena calls that errored: %d / %d (%.0f%%) — from %d of %d rows carrying the field"
          % (se, sc, 100.0 * se / sc, len(err_rows), len(rows)))
elif sc_all:
    print("  serena calls: %d total, %d in rows that record errors" % (sc_all, sc))
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
