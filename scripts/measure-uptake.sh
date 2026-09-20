#!/usr/bin/env bash
# Where should a rule live? Measure, do not guess.
#
# This harness carries rules in three places, and they are not interchangeable:
#
#   resident   ~/.claude/CLAUDE.md   (rules/*.md + tools.md, assembled by sync)
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
  ATTEMPTS="${OMA_UPTAKE_DIR:-$HOME/.claude/uptake}/attach.jsonl"
  DELIVERIES="${OMA_UPTAKE_DIR:-$HOME/.claude/uptake}/delivery.jsonl"
  GRAPH_IMPACTS="${OMA_UPTAKE_DIR:-$HOME/.claude/uptake}/opportunity.jsonl"
  [ -f "$ROWS" ] || [ -f "$ATTEMPTS" ] || [ -f "$GRAPH_IMPACTS" ] || {
    echo "no uptake ledgers yet: $ATTEMPTS (Serena), $GRAPH_IMPACTS (graph impact), or $ROWS (SessionEnd)" >&2
    exit 1
  }
  command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
  python3 - "$ROWS" "$ATTEMPTS" "$DELIVERIES" "$GRAPH_IMPACTS" <<'PYEOF'
import json, sys

raw = []
try:
    for line in open(sys.argv[1], errors="ignore"):
        line = line.strip()
        if not line:
            continue
        try:
            raw.append(json.loads(line))
        except ValueError:
            continue
except OSError:
    pass

def ledger(path):
    rows = []
    try:
        for line in open(path, errors="ignore"):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("schema_version") == 1:
                rows.append(row)
    except OSError:
        pass
    return rows

attempt_rows = ledger(sys.argv[2])
delivery_rows = ledger(sys.argv[3])
graph_impact_rows = [row for row in ledger(sys.argv[4]) if row.get("tool") == "graph-impact"]
attempts = {}
unjoinable = 0
for row in attempt_rows:
    event_id = row.get("event_id")
    if row.get("record_type") == "attempt_terminal" and row.get("outcome") == "unjoinable":
        unjoinable += 1
    if not event_id or not row.get("session_id"):
        continue
    state = attempts.setdefault((row["session_id"], event_id), {"opportunity": 0, "started": 0, "terminal": 0})
    if row.get("record_type") == "opportunity":
        state["opportunity"] += 1
    elif row.get("record_type") == "attempt_started":
        state["started"] += 1
    elif row.get("record_type") == "attempt_terminal":
        state["terminal"] += 1

opportunities = sum(1 for state in attempts.values() if state["opportunity"] == 1)
started = sum(1 for state in attempts.values() if state["opportunity"] == 1 and state["started"] == 1)
terminals = sum(1 for state in attempts.values()
                if state["opportunity"] == 1 and state["started"] == 1 and state["terminal"] == 1)
delivered = [row for row in delivery_rows
             if row.get("record_type") == "delivery" and row.get("tool") in (None, "serena-attach")]
consumption_rows = [row for row in delivery_rows
                    if row.get("record_type") == "consumption" and row.get("tool") in (None, "serena-attach")]
consumption_rank = {"window_incomplete": 0, "no_match_in_three_calls": 1, "matched_named_path": 2}
consumption_by_event = {}
for row in consumption_rows:
    key = (row.get("session_id"), row.get("event_id"), row.get("join_index"))
    previous = consumption_by_event.get(key)
    if previous is None or consumption_rank.get(row.get("outcome"), -1) > consumption_rank.get(previous.get("outcome"), -1):
        consumption_by_event[key] = row
consumption = list(consumption_by_event.values())
join_counts = {kind: sum(1 for row in delivery_rows
                         if row.get("record_type") == kind and row.get("tool") in (None, "serena-attach"))
               for kind in ("invalid_join", "duplicate_join", "orphan_delivery")}
matched = sum(1 for row in consumption if row.get("outcome") == "matched_named_path")
no_match = sum(1 for row in consumption if row.get("outcome") == "no_match_in_three_calls")
incomplete = sum(1 for row in consumption if row.get("outcome") == "window_incomplete")

print("-- Serena adoption funnel (typed ledgers) --")
print("  opportunity : %d" % opportunities)
print("  attempt     : %d" % started)
print("  terminal    : %d" % terminals)
print("  delivery    : %d" % len(delivered))
print("  consumption : %d (matched named path: %d; no match in three calls: %d; incomplete window: %d)"
      % (len(consumption), matched, no_match, incomplete))
print("  unjoinable attempts : %d" % unjoinable)
print("  invalid joins       : %d" % join_counts["invalid_join"])
print("  duplicate joins     : %d" % join_counts["duplicate_join"])
print("  orphan deliveries   : %d" % join_counts["orphan_delivery"])
modes = {row.get("mode") for row in attempt_rows + delivery_rows
         if row.get("mode") in ("headless", "interactive")}
if modes:
    print("  trusted runtime-mode splits:")
    for mode in ("headless", "interactive"):
        print("    %-11s opportunities: %d, deliveries: %d" %
              (mode,
               sum(1 for row in attempt_rows if row.get("record_type") == "opportunity" and row.get("mode") == mode),
               sum(1 for row in delivered if row.get("mode") == mode)))
else:
    print("  runtime mode : not recorded (no trusted headless/interactive data)")
print()

# Lifecycle completion is not delivery. SessionEnd observes the typed
# async_hook_response and writes a tool_use_id-keyed delivery receipt.
graph_impacts = {}
for row in graph_impact_rows:
    event_id = row.get("event_id")
    session_id = row.get("session_id")
    if not isinstance(event_id, str) or not event_id or not isinstance(session_id, str):
        continue
    state = graph_impacts.setdefault((session_id, event_id), {"opportunity": 0, "started": 0, "terminal": []})
    if row.get("record_type") == "opportunity":
        state["opportunity"] += 1
    elif row.get("record_type") == "attempt_started":
        state["started"] += 1
    elif row.get("record_type") == "attempt_terminal":
        state["terminal"].append(row.get("outcome"))

impact_opportunities = sum(1 for state in graph_impacts.values() if state["opportunity"] == 1)
impact_attempts = sum(1 for state in graph_impacts.values()
                      if state["opportunity"] == 1 and state["started"] == 1)
impact_terminals = sum(1 for state in graph_impacts.values()
                       if state["opportunity"] == 1 and state["started"] == 1 and len(state["terminal"]) == 1)
impact_delivery_rows = [row for row in delivery_rows
                        if row.get("record_type") == "delivery" and row.get("tool") == "graph-impact"]
impact_deliveries = len(impact_delivery_rows)
impact_invalid = sum(1 for row in delivery_rows if row.get("tool") == "graph-impact"
                     and row.get("record_type") in ("invalid_join", "duplicate_join", "orphan_delivery"))
print("-- Graph-impact funnel (typed tool_use_id only) --")
print("  opportunity : %d" % impact_opportunities)
print("  attempt     : %d" % impact_attempts)
print("  terminal    : %d" % impact_terminals)
print("  delivery    : %d" % impact_deliveries)
print("  invalid join: %d" % impact_invalid)
print()
if not raw:
    raise SystemExit(0)

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
print("-- symbol-search-gate (retired 2026-08-16): what it did while it ran --")
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
        # The sunset check that used to follow (escape share vs its 54% baseline)
        # is gone with the gate. It never reached its 20-firing threshold: the
        # gate was retired 2026-08-16 on the direct measurement instead — rg
        # returned the definition in 205/205 sampled lookups, serena answered
        # 73x slower, and every serena call the gate redirected in the target
        # repo failed with "No active project". Rows above are kept readable so
        # that record survives; nothing here decides anything any more.
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
# The three tools installed 2026-08-16 (ocr, semantica, karpathy-guidelines).
# The 2026-08-07 survey predicted 0-5% uptake for anything the model must
# choose to call; this block is where that prediction gets checked. Key-absent
# rule again, and it bites harder here than anywhere: every row before the
# install day lacks these keys, so a .get(k, 0) sum would print "0 sessions"
# for a window in which the tools did not exist yet. Only rows that CARRY the
# key are a denominator; rows without it are reported as such.
print("-- tools installed 2026-08-16: are they used at all? --")
INSTALLED = (("nav", "ocr", "ocr (Bash)"), ("nav", "semantica", "semantica (MCP)"),
             ("skills", "karpathy", "karpathy skill"), ("skills", "ponytail", "ponytail skill"))
for key, sub, label in INSTALLED:
    carrying = [r for r in rows if sub in (r.get(key) or {})]
    if not carrying:
        print("  %-16s not recorded — no session in window postdates the counter" % label)
        continue
    used = sum(1 for r in carrying if r[key][sub] > 0)
    calls = sum(r[key][sub] for r in carrying)
    print("  %-16s %d of %d sessions (%.0f%%), %d calls — from rows carrying the field"
          % (label, used, len(carrying), 100.0 * used / len(carrying), calls))
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
print("-- retired per-turn channel: historical duplicate injection cost --")
total_inject = sum(inject_records.values())
worst = inject_records.most_common(1)
print(f"rule injections      : {total_inject} across {len(inject_records)} sessions")
if worst:
    sid, count = worst[0]
    print(f"worst session        : {count} injections ({sid[:8]}…)")
print("current injections   : retired; global managed contract is the only resident source")
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
