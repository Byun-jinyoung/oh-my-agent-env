#!/usr/bin/env bash
# Append an agent work-journal entry to the Obsidian vault.
#
#   scripts/journal.sh add "fixed hook registration drift" \
#       --outcome done --evidence "bash scripts/check.sh" --next "port change-guard"
#   scripts/journal.sh path      # today's journal file
#   scripts/journal.sh show      # print it
#
# Writes to  $OMA_VAULT/Planner/Agent-Journal/YYYY-MM-DD.md  — a dedicated file,
# NOT the user's daily note. The daily note is Templater-owned and holds
# hand-written sections; the vault is Syncthing-backed, so a file the harness
# rewrites can pick up a sync conflict copy. Keeping that blast radius on a file
# only the harness writes is the whole point. Discoverability comes from a
# wikilink to the daily note, which makes the entry show up in that note's
# backlinks pane without ever writing to it.
#
# Fail-open by contract: journalling is bookkeeping, never a gate. Every failure
# path warns on stderr and exits 0 so a caller can chain it without guarding.
set -uo pipefail

VAULT="${OMA_VAULT:-$HOME/PROject/vault}"
JOURNAL_REL="Planner/Agent-Journal"

warn() { echo "journal: $*" >&2; }

cmd="${1:-}"; shift || true

case "$cmd" in
  add|path|show) ;;
  ""|-h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) warn "unknown command: $cmd"; exit 0 ;;
esac

if [ ! -d "$VAULT" ]; then
  warn "vault not found: $VAULT (set OMA_VAULT) — skipping"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 missing — skipping"
  exit 0
fi

DAY="$(date +%F)"
FILE="$VAULT/$JOURNAL_REL/$DAY.md"

if [ "$cmd" = path ]; then echo "$FILE"; exit 0; fi
if [ "$cmd" = show ]; then
  [ -f "$FILE" ] && cat "$FILE" || warn "no journal for $DAY"
  exit 0
fi

SUMMARY="${1:-}"; shift || true
if [ -z "$SUMMARY" ]; then warn "add requires a summary"; exit 0; fi

REPO="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo -)"
OUTCOME=""; EVIDENCE=""; NEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--outcome|--evidence|--next)
      # `shift 2` with only one argument left fails without consuming anything,
      # and this loop has no `set -e` to stop it — it would spin forever.
      if [ $# -lt 2 ]; then warn "$1 needs a value — ignoring"; shift; continue; fi
      case "$1" in
        --repo)     REPO="$2" ;;
        --outcome)  OUTCOME="$2" ;;
        --evidence) EVIDENCE="$2" ;;
        --next)     NEXT="$2" ;;
      esac
      shift 2 ;;
    *) warn "ignoring unknown option: $1"; shift ;;
  esac
done

python3 - "$FILE" "$DAY" "$SUMMARY" "$REPO" "$BRANCH" "$OUTCOME" "$EVIDENCE" "$NEXT" <<'PYEOF' || warn "write failed — entry not recorded"
import os, sys, tempfile, time
from pathlib import Path

path, day, summary, repo, branch, outcome, evidence, nxt = (
    Path(sys.argv[1]), *sys.argv[2:9]
)
BEGIN = "<!-- OMA-WORK-JOURNAL:BEGIN schema=1 -->"
END = "<!-- OMA-WORK-JOURNAL:END -->"

def esc(s):
    # Keep one entry on one line and keep pipes from breaking the row shape.
    # Neutralise the block markers too: a summary containing the end marker
    # would otherwise terminate the managed block early and every later entry
    # would be appended outside it, where the next run cannot find them.
    out = " ".join(str(s).split()).replace("|", "\\|")
    return out.replace("<!--", "<!‑‑").replace("-->", "‑‑>")

fields = [f"`{esc(repo)}`@`{esc(branch)}`", esc(summary)]
if outcome:  fields.append(f"outcome=`{esc(outcome)}`")
if evidence: fields.append(f"evidence=`{esc(evidence)}`")
if nxt:      fields.append(f"next={esc(nxt)}")
entry = f"- {time.strftime('%H:%M')} · " + " · ".join(fields) + "\n"

if path.exists():
    old = path.read_text(encoding="utf-8")
else:
    old = (
        "---\n"
        f"date: {day}\n"
        "tags:\n  - agent-journal\n"
        "---\n\n"
        f"# Agent Journal {day}\n\n"
        f"Daily note: [[{day}]]\n\n"
        f"{BEGIN}\n{END}\n"
    )

if BEGIN in old and END in old:
    head, rest = old.split(BEGIN, 1)
    body, tail = rest.split(END, 1)
    body = body.strip("\n")
    body = (body + "\n" + entry.rstrip("\n")) if body else entry.rstrip("\n")
    new = f"{head}{BEGIN}\n{body}\n{END}{tail}"
else:
    # Markers lost (hand-edited or sync conflict): append a fresh block rather
    # than rewriting anything the user may have changed.
    new = old.rstrip("\n") + f"\n\n{BEGIN}\n{entry.rstrip()}\n{END}\n"

path.parent.mkdir(parents=True, exist_ok=True)
fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
tmp = Path(tmp_name)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(new)
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
except BaseException:
    tmp.unlink(missing_ok=True)
    raise
print(f"journal: {path}")
PYEOF
exit 0
