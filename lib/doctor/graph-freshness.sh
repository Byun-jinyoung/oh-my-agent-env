#!/usr/bin/env bash
# Is the code graph in each repo actually usable, or just present?
#
# Measured on the research worktree that prompted this: the CRG graph was built
# at 0c0ebdcd while HEAD was 785f565f — 351 commits and 51 changed source files
# later, covering every directory the work touched. doctor said nothing, because
# what it checked was that the `graphify` command resolves and that SKILL.md is
# on disk. That is stage one of five (installed → produced data → data current →
# reachable from a session → actually consulted), and the harness was scoring
# stage one as health. Exactly the shape of the serena configs that were
# installed, prescribed in prose, and unloadable.
#
# A stale graph is worse than a missing one. Missing is obvious the moment you
# look; stale answers confidently about code that has since moved.
#
# Staleness is measured by commits landed after the artifact's mtime rather than
# by parsing `code-review-graph status`: that means one cheap git call per repo
# instead of opening a 52MB SQLite database, and it works the same for graphify,
# whose output carries no build-commit field at all.
#
# Reports only. Reading a repo's git log is safe anywhere; rebuilding a graph
# costs minutes and writes into someone else's project, so the command to run is
# printed and not executed.
set -uo pipefail

# artifact path -> the command that produces it
GRAPHS="graphify-out/graph.json:graphify update .
.code-review-graph/graph.db:code-review-graph update"

seen=""
for repo in "$@"; do
  [ -d "$repo" ] || continue
  repo="$(cd "$repo" 2>/dev/null && pwd -P)" || continue
  case " $seen " in *" $repo "*) continue ;; esac
  seen="$seen $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
  short="$(basename "$repo")"

  printf '%s\n' "$GRAPHS" | while IFS=: read -r rel cmd; do
    [ -n "$rel" ] || continue
    art="$repo/$rel"
    tool="${rel%%/*}"
    if [ ! -f "$art" ]; then
      # Absent is worth a line. graphify was installed, prescribed in CLAUDE.md
      # and mirrored into two skill trees while producing output in no checkout
      # at all — and nothing said so, because nothing looked.
      echo "  [MISS] $short: no $rel — run: $cmd"
      continue
    fi
    # Commits that landed after the graph was written. --since takes an epoch
    # with @, so no date formatting has to agree between git and the shell.
    # Prefer the commit the graph RECORDS over the file's mtime. CRG stores it
    # in a metadata table, and mtime lies: opening the database to read it
    # rewrites the timestamp, so a graph built 351 commits ago reported itself
    # current the first time this check ran. An artifact's age is not the age
    # of the code inside it.
    built=""
    case "$rel" in
      *.db) built="$(python3 - "$art" <<'PY' 2>/dev/null || true
import sqlite3, sys
try:
    con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
    row = con.execute("select value from metadata where key='git_head_sha'").fetchone()
    print(row[0] if row else "")
except Exception:
    pass
PY
)" ;;
    esac
    behind=0; basis="mtime"
    if [ -n "$built" ] && git -C "$repo" cat-file -e "$built^{commit}" 2>/dev/null; then
      basis="recorded commit ${built:0:8}"
      behind="$(git -C "$repo" rev-list --count "$built..HEAD" 2>/dev/null || echo 0)"
    else
      # Fallback for a graph that records nothing (graphify writes no build
      # commit). Gate on a STRICT comparison against HEAD's commit time:
      # `--since` is inclusive, so a graph written in the same second as the
      # commit it describes counted that commit and every fresh build reported
      # itself stale.
      mtime="$(stat -c %Y "$art" 2>/dev/null || echo 0)"
      head_ct="$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 0)"
      if [ "${head_ct:-0}" -gt "${mtime:-0}" ]; then
        behind="$(git -C "$repo" rev-list --count --since="@$mtime" HEAD 2>/dev/null || echo 0)"
      fi
    fi
    if [ "${behind:-0}" -gt 0 ]; then
      echo "  [STALE] $short: $rel is $behind commit(s) behind HEAD ($basis) — run: $cmd"
    else
      echo "  [OK] $short: $rel is current with HEAD ($basis)"
    fi
    # Only worth saying for an artifact that exists: the harness tells the model
    # to run `graphify update .`, which drops graphify-out/ into the repo root.
    # In a project whose .gitignore never heard of it that is untracked noise in
    # someone else's tree — a good reason not to run the tool, and one the
    # operator hit before running it.
    if ! git -C "$repo" check-ignore -q "$rel" 2>/dev/null; then
      echo "         $tool/ is not ignored here — add '$tool/' to .gitignore before rebuilding"
    fi
  done
done
