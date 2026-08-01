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
check "capsule is listed"                'bash "$OMA_LAB" capsule list | grep -q .'
check "whence traces the checkpoint back" \
      'bash "$OMA_LAB" capsule whence ckpt/model_seed2.pt | grep -q run='

# --- fail: the retry loop across sessions ------------------------------------
lab fail record --cmd "python3 train.py --bogus" --exit 2 --note "no such flag"
lab fail check --cmd "python3 train.py --bogus"
check "a known failure is re-reported (exit 3)" '[ "$RC" -eq 3 ]'
lab fail check --cmd "python3 train.py 3"
check "an unseen command is not blocked" '[ "$RC" -ne 3 ]'
lab fail resolve --cmd "python3 train.py --bogus" --note "fixed"
lab fail check --cmd "python3 train.py --bogus"
check "a resolved failure stops blocking" '[ "$RC" -ne 3 ]'

# --- containment --------------------------------------------------------------
check "state lands in the target repo" '[ -d "$WORK/.oma-lab" ]'
check "no state in the harness"        '[ ! -e "$ROOT/.oma-lab" ]'
(cd "$ROOT" && git status --porcelain) > "$TMP/harness-after" 2>/dev/null
check "harness working tree untouched" 'diff -q "$HARNESS_BEFORE" "$TMP/harness-after"'

exit "$FAILED"
