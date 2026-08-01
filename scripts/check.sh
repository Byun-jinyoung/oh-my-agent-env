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
  if command -v shellcheck >/dev/null 2>&1; then
    stage "shellcheck" lint_shellcheck
  elif [ "${OMA_REQUIRE_SHELLCHECK:-0}" = 1 ]; then
    echo "  [FAIL] shellcheck required but not installed"
    FAILED=1
  else
    echo "  [SKIP] shellcheck not installed (CI enforces it; apt install shellcheck)"
  fi
fi

# Tests run in a separate pass so one lint nit does not hide every test result —
# without the split, the first failure suppresses the signal you actually wanted.
if [ "$TESTS" = 1 ]; then
  echo "[tests]"
  stage "smoke-refactor"  bash tests/smoke-refactor.sh
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
