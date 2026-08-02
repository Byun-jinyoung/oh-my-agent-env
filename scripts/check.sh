#!/usr/bin/env bash
# Single verification gate for oh-my-agent-env. Run locally before committing;
# CI runs the same entry point so local green and CI green mean the same thing.
#
#   scripts/check.sh              lint + tests
#   scripts/check.sh --lint-only  syntax/static checks only
#   scripts/check.sh --no-lint    tests only
#
# Flags rather than env vars: an env prefix (LINT=0 scripts/check.sh) exports
# into every descendant, and the smoke suite spawns setup.sh, which would then
# see a variable meant for the gate.
#
# The shellcheck stage is required in CI (OMA_REQUIRE_SHELLCHECK=1) and skipped
# with a
# visible notice locally, so a machine without it can still run the gate instead
# of having no gate at all.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || { echo "cannot cd to repo root: $ROOT" >&2; exit 2; }

# Read the pinned version out of the workflow rather than restating it here.
# A second copy of the number is a second thing to forget on a bump, and the
# whole point of printing it is to expose drift, not to add a new source of it.
SHELLCHECK_PINNED="$(sed -n 's/.*SHELLCHECK_VERSION:[[:space:]]*v\([0-9.]*\).*/\1/p' \
  .github/workflows/test.yml 2>/dev/null | head -1)"
SHELLCHECK_PINNED="${SHELLCHECK_PINNED:-unknown}"

LINT=1
TESTS=1
case "${1:-}" in
  --lint-only) TESTS=0 ;;
  --no-lint)   LINT=0 ;;
  "")          ;;
  -h|--help)   sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *)           echo "unknown flag: $1" >&2; exit 2 ;;
esac

FAILED=0
stage() {
  local name="$1"; shift
  local log; log="$(mktemp "${TMPDIR:-/tmp}/oma-check.XXXXXX")"
  if "$@" >"$log" 2>&1; then
    printf '  [OK]   %s\n' "$name"
  else
    printf '  [FAIL] %s\n' "$name"
    sed 's/^/         /' "$log"
    FAILED=1
  fi
  rm -f "$log"
}

shell_files() {
  printf '%s\n' setup.sh
  # oma-lab is named explicitly: it has no .sh extension, so the glob below
  # skips it and it would ship unlinted.
  [ -f scripts/oma-lab ] && printf '%s\n' scripts/oma-lab
  find lib scripts tests -name '*.sh' -type f 2>/dev/null | sort
}

lint_shellcheck() {
  local files; mapfile -t files < <(shell_files)
  shellcheck -x -S warning "${files[@]}"
}

lint_bash_syntax() {
  local f
  while IFS= read -r f; do bash -n "$f" || return 1; done < <(shell_files)
}

lint_node_syntax() {
  local f
  for f in runtimes/claude/hooks/*.js ui/statusline/*.mjs; do
    [ -f "$f" ] || continue
    node --check "$f" || return 1
  done
}

# The Python this harness embeds in shell — 37 sites and not one of them linted.
# Reproduced before writing this: breaking hook_manifest_scripts' program left
# check.sh reporting PASS, and the damage was worse than a crash. Its `2>/dev/null
# && return 0` swallows the SyntaxError and falls through to the glob, so the
# manifest stops being the SSOT for which hooks get installed and the output
# still looks like a list of hooks.
#
# tests/ is excluded deliberately: its Python runs on every `check.sh`, so a
# syntax error there already fails loudly, and its shell-inside-shell assertions
# are the only shapes this extractor gets wrong.
lint_python_syntax() {
  # The file list goes in argv, not a pipe: `python3 -` reads its PROGRAM from
  # stdin, and the heredoc below is that program. Piping the list in as well
  # silently loses it — first attempt did exactly that and reported 0 blocks.
  local files; mapfile -t files < <(shell_files | grep -v '^tests/')
  python3 - tests/fixtures/python-unextractable.txt "${files[@]}" << 'PYEOF'
import pathlib, re, sys
from collections import Counter

# An invocation, not a mention: `command -v python3` and log lines about python
# do not run any. `-m json.tool` carries no source of ours.
INVOKE  = re.compile(r"(?<!command -v )python3\s+(-c\s|-\s|<<)")
HEREDOC = re.compile(r"<<-?\s*(?P<q>['\"]?)(?P<marker>[A-Za-z_]\w*)(?P=q)")
OPENERS = (re.compile(r"python3\s+-c\s+'"), re.compile(r"\blab_jsonl_query\b[^']*'"))

def sites(path):
    """(kind, line_no, source|None) for each embedded-Python site in one file."""
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        start, line = i, lines[i]
        # A `python3 - "$a" "$b" \` invocation can carry its heredoc marker onto
        # the continuation line; joining first is what makes those reachable.
        while line.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1; line = line.rstrip()[:-1] + lines[i]
        h = HEREDOC.search(line)
        opener = next((m for r in OPENERS if (m := r.search(line))), None)
        if INVOKE.search(line) and h:
            marker, quoted = h.group("marker"), bool(h.group("q"))
            body, i = [], i + 1
            while i < len(lines) and lines[i].strip() != marker:
                body.append(lines[i]); i += 1
            i += 1
            # An unquoted marker means the shell expands $vars inside, so what is
            # on disk is a template and never was a Python program.
            yield (("heredoc", start + 1, "\n".join(body)) if quoted
                   else ("heredoc-expanded", start + 1, None))
            continue
        if opener:
            rest = line[opener.end():]
            body = [rest] if rest.strip() else []
            closed, i = rest.strip().startswith("'"), i + 1
            while i < len(lines) and not closed:
                if lines[i].lstrip().startswith("'"): closed = True; i += 1; break
                body.append(lines[i]); i += 1
            yield (("inline", start + 1, "\n".join(body)) if closed
                   else ("inline-unterminated", start + 1, None))
            continue
        if INVOKE.search(line):
            yield ("unrecognised", start + 1, None)
        i += 1

allowed = Counter()
for raw in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw.split("#", 1)[0].strip()
    if line: allowed[line] += 1

checked = 0; bad = []; blind = Counter()
for name in sys.argv[2:]:
    for kind, lineno, src in sites(pathlib.Path(name)):
        if src is None:
            blind["%s [%s]" % (name, kind)] += 1; continue
        checked += 1
        try: compile(src, "%s:%d" % (name, lineno), "exec")
        except (SyntaxError, ValueError) as exc:
            bad.append("%s:%d: %s" % (name, lineno, exc))

rc = 0
for b in bad: print("python syntax error: %s" % b); rc = 1
# A site this extractor cannot reach is a blind spot, not a pass. Listing it is
# allowed; growing the list by accident is not.
for site, n in sorted((blind - allowed).items()):
    print("unreachable Python site not in the allow-list: %s (x%d)" % (site, n)); rc = 1
for site, n in sorted((allowed - blind).items()):
    print("allow-list entry no longer present, delete it: %s (x%d)" % (site, n)); rc = 1
# Finding nothing and having nothing to find print the same way otherwise.
if not checked:
    print("no embedded Python found — the extractor stopped matching"); rc = 1
print("python syntax: %d block(s), %d allowed-unreachable" % (checked, sum(allowed.values())))
sys.exit(rc)
PYEOF
}

lint_json() {
  local f
  while IFS= read -r f; do
    python3 -m json.tool "$f" >/dev/null || { echo "invalid JSON: $f"; return 1; }
  done < <(git ls-files '*.json' 2>/dev/null; printf '%s\n' runtimes/claude/hooks/manifest.json)
}

if [ "$LINT" = 1 ]; then
  echo "[lint]"
  stage "bash -n"      lint_bash_syntax
  stage "node --check" lint_node_syntax
  stage "json parse"   lint_json
  stage "python syntax" lint_python_syntax
  if command -v shellcheck >/dev/null 2>&1; then
    # Print the version, because shellcheck's diagnostics differ between
    # releases: a local pass on one version is not evidence about another.
    # Showing both numbers turns silent drift into a line you can read.
    sc_have="$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}')"
    stage "shellcheck ${sc_have:-unknown} (CI pins $SHELLCHECK_PINNED)" lint_shellcheck
  elif [ "${OMA_REQUIRE_SHELLCHECK:-0}" = 1 ]; then
    echo "  [FAIL] shellcheck required but not installed"
    FAILED=1
  else
    echo "  [SKIP] shellcheck not installed (CI enforces $SHELLCHECK_PINNED)"
    echo "         https://github.com/koalaman/shellcheck/releases/tag/v$SHELLCHECK_PINNED"
  fi
fi

# Tests run in a separate pass so one lint nit does not hide every test result —
# without the split, the first failure suppresses the signal you actually wanted.
if [ "$TESTS" = 1 ]; then
  echo "[tests]"
  stage "smoke-refactor"  bash tests/smoke-refactor.sh
  # Separate from the smoke suite because it fails for different reasons: the
  # smoke suite asks whether the harness is assembled right, this one asks
  # whether the experiment tools work when actually driven at a repo. Every
  # structural check passed while read-only verbs were creating state on disk.
  if [ -f tests/lab-e2e.sh ]; then
    stage "lab e2e" bash tests/lab-e2e.sh
  fi
  if [ -f runtimes/claude/hooks/test-pre-edit-gate.js ]; then
    stage "pre-edit-gate fixtures" node runtimes/claude/hooks/test-pre-edit-gate.js
  fi
fi

if [ "$FAILED" = 0 ]; then
  echo "check: PASS"
else
  echo "check: FAIL" >&2
fi
exit "$FAILED"
