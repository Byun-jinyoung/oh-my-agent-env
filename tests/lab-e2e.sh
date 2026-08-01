#!/usr/bin/env bash
# End-to-end exercise of the oma-lab experiment tools.
#
# smoke-refactor.sh checks that the harness is assembled correctly; this checks
# that the experiment tools actually work when driven against a repo. They are
# separate concerns and separate failure modes: every structural check passed
# while `oma-lab fail --help` was quietly creating a .oma-lab/ directory in
# whatever directory it was run from, including the harness checkout.
#
# The fixture is shaped like the real workload — a git repo with its own gate,
# a training script that writes a checkpoint, metrics worth ranking, and a run
# that is supposed to fail — because the tools' whole value is in that shape.
#
# Everything happens under a sandbox TMPDIR. The harness must come out byte for
# byte as it went in; that is the last assertion.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OMA_LAB="$ROOT/scripts/oma-lab"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/oma-lab-e2e.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAILED=0
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAILED=1; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# Exit status of the last `lab` call, captured explicitly. Reading $? from
# inside check()'s eval works only as long as nothing is inserted between the
# command and the assertion — a silent tautology waiting for the next edit.
RC=0
# shellcheck disable=SC2034  # RC is read inside check()'s eval, which shellcheck cannot follow
lab() { bash "$OMA_LAB" "$@" >/dev/null 2>&1; RC=$?; return 0; }

command -v git     >/dev/null 2>&1 || { echo "  [SKIP] lab e2e: git missing";     exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "  [SKIP] lab e2e: python3 missing"; exit 0; }

HARNESS_BEFORE="$TMP/harness-before"
(cd "$ROOT" && git status --porcelain) > "$HARNESS_BEFORE" 2>/dev/null
# shellcheck disable=SC2034  # read inside check()'s eval, which shellcheck cannot follow
EXCLUDE_BEFORE="$(cat "$ROOT/.git/info/exclude" 2>/dev/null | sha256sum)"

# --- read-only verbs must not create state ----------------------------------
# The regression this file exists for. lab_state_dir() used to mkdir -p as a
# side effect of being asked for a path, so asking for help wrote to disk.
probe="$TMP/probe"; mkdir -p "$probe"
(
  cd "$probe" || exit 1
  git init -q .
  for verb in "--help" "board --help" "capsule list" "fail list" "board list"; do
    rm -rf .oma-lab
    # shellcheck disable=SC2086
    bash "$OMA_LAB" $verb >/dev/null 2>&1
    [ -d .oma-lab ] && { echo "$verb"; exit 1; }
  done
  exit 0
) >"$TMP/probe.out" 2>&1
if [ -s "$TMP/probe.out" ]; then
  bad "read-only verbs create no state (offender: $(cat "$TMP/probe.out"))"
else
  ok "read-only verbs create no state"
fi

# --- fixture -----------------------------------------------------------------
WORK="$TMP/repo"; mkdir -p "$WORK"
cd "$WORK" || exit 1
git init -q .
git config user.email e2e@local
git config user.name e2e
mkdir -p scripts data
printf 'smiles,y\nCCO,1.2\nCCN,0.8\n' > data/train.csv

cat > scripts/check.sh <<'GATE'
#!/usr/bin/env bash
# The research repo's own pre-flight gate. `oma-lab run` must honour it.
[ -f data/train.csv ] || { echo "dataset missing"; exit 1; }
echo "repo gate: OK"
GATE
chmod +x scripts/check.sh

cat > train.py <<'TRAIN'
import json, os, sys
seed = int(sys.argv[1]) if len(sys.argv) > 1 else 0
rmse = round(0.50 - seed * 0.07, 4)          # deterministic: no RNG, no flake
os.makedirs("ckpt", exist_ok=True)
open("ckpt/model_seed%d.pt" % seed, "w").write("weights seed=%d\n" % seed)
json.dump({"val_rmse": rmse, "seed": seed}, open("metrics.json", "w"))
print("val_rmse=%s" % rmse)
TRAIN

git add -A && git commit -qm "fixture: dataset, gate, training script"

# --- board: claiming an id is what stops two sessions duplicating work --------
lab board claim --id seed-sweep --hypothesis "higher seed lowers rmse"
check "board records the claim" 'bash "$OMA_LAB" board list | grep -q seed-sweep'
lab board claim --id seed-sweep --hypothesis "duplicate"
check "board refuses a second claim of the same id" '[ "$RC" -ne 0 ]'
# The exit code alone would pass even if the duplicate row were appended and
# the refusal were cosmetic. Count the rows.
check "the refused claim wrote no row" \
      '[ "$(wc -l < .oma-lab/experiments.jsonl)" -eq 1 ]'

# --- run: the ledger records what was tried ----------------------------------
for s in 0 1 2; do
  m="$(python3 -c "print(round(0.50-$s*0.07,4))")"
  lab run --tag sweep --metrics "val_rmse=$m" -- python3 train.py "$s"
  check "run seed=$s exits 0" '[ "$RC" -eq 0 ]'
done
check "ledger holds three runs" '[ "$(wc -l < .oma-lab/ledger.jsonl)" -eq 3 ]'
check "the run produced its checkpoint" '[ -f ckpt/model_seed2.pt ]'

# --- run: a failing gate must abort BEFORE the command burns GPU time --------
mv data/train.csv data/train.csv.hidden
lab run --tag gated -- python3 train.py 9
check "gated run exits nonzero" '[ "$RC" -ne 0 ]'
check "gated run never executed the command" '[ ! -f ckpt/model_seed9.pt ]'
mv data/train.csv.hidden data/train.csv

# --- top: rank by a recorded metric ------------------------------------------
check "top --min surfaces the best run" \
      'bash "$OMA_LAB" top --metric val_rmse --min -n 1 | grep -q 0.36'

# --- capsule: a number stays traceable to what produced it -------------------
lab capsule save --config data/train.csv --output ckpt/model_seed2.pt \
  --note "best of the seed sweep"
# `capsule list | grep -q .` would pass on the empty-index output, which is
# still a line: "(0 capsule(s))". Assert the index actually gained a row.
check "capsule index gained a row"       '[ "$(wc -l < .oma-lab/capsules.jsonl)" -eq 1 ]'
check "capsule list reports it"          'bash "$OMA_LAB" capsule list | grep -qv "(0 capsule"'
check "whence traces the checkpoint back" \
      'bash "$OMA_LAB" capsule whence ckpt/model_seed2.pt | grep -q run='

# --- fail: the retry loop across sessions ------------------------------------
lab fail record --cmd "python3 train.py --bogus" --exit 2 --note "no such flag"
lab fail check --cmd "python3 train.py --bogus"
check "a known failure is re-reported (exit 3)" '[ "$RC" -eq 3 ]'
# `!= 3` would also accept an unrelated error such as 1, so these pin 0 exactly:
# the point is that the command is cleared to run, not merely that some other
# failure occurred.
lab fail check --cmd "python3 train.py 3"
check "an unseen command is cleared to run" '[ "$RC" -eq 0 ]'
lab fail resolve --cmd "python3 train.py --bogus" --note "fixed"
lab fail check --cmd "python3 train.py --bogus"
check "a resolved failure is cleared to run" '[ "$RC" -eq 0 ]'

# --- --repo: state must land in ONE repo, the named one ----------------------
# The ledger path used to be resolved before --repo was parsed, so a run
# launched from elsewhere split its state: ledger.jsonl in the caller's repo,
# CURRENT in the target. Launched from the harness, that wrote into the harness.
launcher="$TMP/launcher"; target="$TMP/target"
mkdir -p "$launcher" "$target"
(cd "$launcher" && git init -q .)
(cd "$target"   && git init -q .)
( cd "$launcher" && bash "$OMA_LAB" run --repo "$target" --no-gate --reason e2e -- true ) >/dev/null 2>&1
check "--repo keeps the ledger out of the caller's repo" '[ ! -e "$launcher/.oma-lab/ledger.jsonl" ]'
check "--repo puts the ledger in the named repo"         '[ -f "$target/.oma-lab/ledger.jsonl" ]'
check "--repo keeps CURRENT with the ledger"             '[ -f "$target/.oma-lab/CURRENT" ]'
# A typo'd --repo must not silently record against the caller instead.
( cd "$launcher" && bash "$OMA_LAB" fail record --repo "$TMP/no-such-repo" --cmd false ) >/dev/null 2>&1
check "a bad --repo is refused, not redirected" '[ ! -e "$launcher/.oma-lab/failures.jsonl" ]'

# --- a write that cannot happen must not report success ----------------------
# root ignores the write bit, so the setup would not actually block anything and
# the assertion would pass for the wrong reason. Skip rather than lie.
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP  unwritable-repo checks (running as root; chmod u-w has no effect)"
else
  blocked="$TMP/blocked"; mkdir -p "$blocked"
  (cd "$blocked" && git init -q .)
  chmod u-w "$blocked"
  ( cd "$blocked" && bash "$OMA_LAB" board claim --id nope ) >/dev/null 2>&1
  blocked_rc=$?
  chmod u+w "$blocked"
  check "an unwritable repo fails loudly" '[ "'"$blocked_rc"'" -ne 0 ]'

  # ...except after the command has already run. That append is the one place
  # where dying would trade a real result for a record of it: `run` promises to
  # exit with the command's status, and on a long job that status is the result.
  ec="$TMP/exitcode"; mkdir -p "$ec"
  (cd "$ec" && git init -q .)
  ( cd "$ec" && bash "$OMA_LAB" run --no-gate --reason setup -- true ) >/dev/null 2>&1
  chmod 0444 "$ec/.oma-lab/ledger.jsonl"
  ec_out="$( cd "$ec" && bash "$OMA_LAB" run --no-gate --reason probe -- sh -c 'exit 7' 2>&1 )"
  ec_rc=$?
  chmod 0644 "$ec/.oma-lab/ledger.jsonl"
  check "an unwritable ledger does not swallow the command's exit code" '[ "'"$ec_rc"'" -eq 7 ]'
  check "and it says so out loud" \
        'printf "%s" "'"$ec_out"'" | grep -q "could NOT be recorded"'
fi

# --- containment --------------------------------------------------------------
check "state lands in the target repo" '[ -d "$WORK/.oma-lab" ]'
check "no state in the harness"        '[ ! -e "$ROOT/.oma-lab" ]'
# git status cannot see this one: lab_ensure_gitignore writes .git/info/exclude,
# which is not a tracked path and never shows up as a modification.
check "harness .git/info/exclude untouched" \
      '[ "$(cat "$ROOT/.git/info/exclude" 2>/dev/null | sha256sum)" = "$EXCLUDE_BEFORE" ]'
(cd "$ROOT" && git status --porcelain) > "$TMP/harness-after" 2>/dev/null
check "harness working tree untouched" 'diff -q "$HARNESS_BEFORE" "$TMP/harness-after"'

exit "$FAILED"
