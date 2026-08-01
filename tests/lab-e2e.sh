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
# Without --repo, a path means what the caller meant: relative to where they
# are standing. Fixing the --repo case by moving to the repo root
# unconditionally broke this, and the damage was silent — a capsule that
# records "missing:" still saves, still exits 0, and still lists.
mkdir -p sub/out; printf 'w\n' > sub/out/local.pt
( cd sub && bash "$OMA_LAB" capsule save --output out/local.pt --note subdir ) >/dev/null 2>&1
check "capsule resolves a path against the caller's cwd when no --repo is given" \
      '! grep -q "missing:out/local.pt" .oma-lab/capsules.jsonl'

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

# --- data: which split produced the number, and is it still that split? ------
# A commit hash cannot answer this: the splits are gitignored, so the tree is
# clean whatever the CSVs say.
printf 'id,scaffold,y\nm1,A,1.0\nm2,B,2.0\nm3,A,3.0\n' > data/train_s.csv
printf 'id,scaffold,y\nm4,C,4.0\nm5,D,5.0\n'           > data/valid_s.csv
lab data register --name qm9 --id-column id --key-column scaffold \
  --split train=data/train_s.csv --split valid=data/valid_s.csv
check "register records the dataset" '[ "$(wc -l < .oma-lab/datasets.jsonl)" -eq 1 ]'
# The point of recording it at all is the join back to the run that consumed it.
check "the registration joins to the current run" \
      'grep -q "\"run_id\": \"$(cat .oma-lab/CURRENT)\"" .oma-lab/datasets.jsonl'
lab data check --name qm9
check "check passes on unchanged splits" '[ "$RC" -eq 0 ]'

# These two assertions only mean something together. Either alone is satisfied
# by a plain file hash, which is what makes them worth writing:
#
#   reordering rows changes every byte of the file but changes no assignment,
#   so a file hash cries drift and this must not;
#   permuting the assignment leaves the id set, the value set and the row count
#   identical, so anything short of the id->value pair hash misses it.
python3 - <<'REORDER'
rows = open("data/train_s.csv").read().splitlines()
open("data/train_s.csv", "w").write("\n".join([rows[0]] + rows[1:][::-1]) + "\n")
REORDER
lab data check --name qm9
check "reordering rows is not drift" '[ "$RC" -eq 0 ]'

printf 'id,scaffold,y\nm1,B,1.0\nm2,A,2.0\nm3,A,3.0\n' > data/train_s.csv
drift_out="$(bash "$OMA_LAB" data check --name qm9 2>&1)"; drift_rc=$?
check "permuting the scaffold assignment is drift" '[ "'"$drift_rc"'" -ne 0 ]'
# Name the field that fired. "exits nonzero" would pass if the row count or the
# id hash had moved, which would mean the pair hash is doing no work at all.
check "and it is the pair hash that fires, not the id set" \
      'printf "%s" "'"$drift_out"'" | grep -q "scaffold pairs changed"'
check "the id set is reported unchanged" \
      '! printf "%s" "'"$drift_out"'" | grep -q "ids changed"'

# leakage: the failure that silently inflates every number downstream.
printf 'id,scaffold,y\nm4,C,4.0\nm2,B,9.9\n' > data/valid_s.csv
lab data leakage --name qm9
check "leakage catches an id in two splits" '[ "$RC" -eq 1 ]'
# Fail-closed. A gate that reports clean because it could not look is worse
# than no gate, and exit 0 here would read as "no leakage" to any caller.
mv data/valid_s.csv data/valid_s.hidden
lab data leakage --name qm9
check "leakage on an unreadable split exits 2, not 0" '[ "$RC" -eq 2 ]'
# One split means no pair to compare, so the loop never runs and the command
# used to exit 0 having printed nothing — indistinguishable from a clean run.
lab data register --name lonely --id-column id --split only=data/train_s.csv
lab data leakage --name lonely
check "leakage with a single split exits 2, not a silent 0" '[ "$RC" -eq 2 ]'
mv data/valid_s.hidden data/valid_s.csv

# Compare against the count taken just before, not against a literal: an
# absolute number silently becomes wrong the moment a registration is added
# anywhere above, and then it is testing the edit rather than the refusal.
# shellcheck disable=SC2034  # read inside check()'s eval, which shellcheck cannot follow
rows_before="$(wc -l < .oma-lab/datasets.jsonl)"
lab data register --name bogus --id-column id --key-column nosuch --split train=data/train_s.csv
check "registering a missing key column is refused" '[ "$RC" -eq 2 ]'
check "the refused registration wrote no row" \
      '[ "$(wc -l < .oma-lab/datasets.jsonl)" -eq "$rows_before" ]'

# Three ways a CSV silently produces the wrong fingerprint or a hollow pass.
# A header with no rows is a failed export; left alone, leakage would call it
# disjoint from everything and that reads as a clean bill of health.
printf 'id,scaffold,y\n' > data/norows.csv
lab data register --name norows --split train=data/norows.csv
check "a split with no rows is refused" '[ "$RC" -eq 2 ]'
# DictReader keeps the last value for a repeated header, so this would
# fingerprint the second 'id' column without saying so.
printf 'id,id,y\nm1,m9,1.0\n' > data/dup.csv
lab data register --name dup --split train=data/dup.csv
check "duplicate columns are refused" '[ "$RC" -eq 2 ]'
# A BOM must be transparent, not merely tolerated: pandas writes one on
# request, and it binds to the first header cell. Equality with the plain file
# is the assertion — "exits 0" would pass while hashing "﻿id" as the id.
printf '\xef\xbb\xbfid,scaffold,y\nm1,A,1.0\nm2,B,2.0\n' > data/bom.csv
printf 'id,scaffold,y\nm1,A,1.0\nm2,B,2.0\n'             > data/nobom.csv
lab data register --name bom   --split train=data/bom.csv   --key-column scaffold
lab data register --name nobom --split train=data/nobom.csv --key-column scaffold
check "a BOM fingerprints identically to the same file without one" \
      'python3 -c "
import json
d={}
for l in open(\".oma-lab/datasets.jsonl\"):
    r=json.loads(l); d[str(r[\"name\"])]=json.loads(r[\"splits\"])
import sys
a=dict(d[\"bom\"][\"train\"]); b=dict(d[\"nobom\"][\"train\"])
a.pop(\"path\"); b.pop(\"path\")   # the filenames differ; nothing else may
sys.exit(0 if a==b else 1)"'
# --- --repo: state must land in ONE repo, the named one ----------------------
# The ledger path used to be resolved before --repo was parsed, so a run
# launched from elsewhere split its state: ledger.jsonl in the caller's repo,
# CURRENT in the target. Launched from the harness, that wrote into the harness.
launcher="$TMP/launcher"; target="$TMP/target"
mkdir -p "$launcher" "$target"
# Distinct commits in each. Without them both repos answer "no-head" and the
# "whose commit got recorded" assertion below is true no matter what the code
# does — the tautology that let this bug through the first round.
for d in "$launcher" "$target"; do
  ( cd "$d" && git init -q . && git config user.email e2e@local && git config user.name e2e \
    && printf '%s\n' "$d" > marker.txt && git add marker.txt && git commit -qm "$(basename "$d")" )
done
# shellcheck disable=SC2034  # read inside check()'s eval, which shellcheck cannot follow
target_head="$(cd "$target" && git rev-parse HEAD)"
# shellcheck disable=SC2034  # read inside check()'s eval, which shellcheck cannot follow
launcher_excl_before="$(sha256sum < "$launcher/.git/info/exclude" 2>/dev/null)"

( cd "$launcher" && bash "$OMA_LAB" run --repo "$target" --no-gate --reason e2e -- true ) >/dev/null 2>&1
check "--repo keeps the ledger out of the caller's repo" '[ ! -e "$launcher/.oma-lab/ledger.jsonl" ]'
check "--repo puts the ledger in the named repo"         '[ -f "$target/.oma-lab/ledger.jsonl" ]'
check "--repo keeps CURRENT with the ledger"             '[ -f "$target/.oma-lab/CURRENT" ]'
# Landing the FILE in the right repo is not the same as describing the right
# repo. The row's whole purpose is answering "which code produced this", and it
# used to answer with the launcher's commit while sitting in the target's ledger.
check "--repo records the target's commit, not the caller's" \
      'grep -q "$target_head" "$target/.oma-lab/ledger.jsonl"'
# Same split, invisible to git status: the exclude line went to the caller and
# the repo that actually gained a .oma-lab/ got none.
check "--repo excludes state in the target, not the caller" \
      '[ "$(sha256sum < "$launcher/.git/info/exclude" 2>/dev/null)" = "$launcher_excl_before" ] &&
       grep -qxF ".oma-lab/" "$target/.git/info/exclude"'

# A typo'd --repo must not silently record against the caller instead.
lab fail record --repo "$TMP/no-such-repo" --cmd false
# Both halves matter: exiting nonzero without writing is correct, but so is a
# broken no-op that writes nothing and exits 0, and only the exit code tells
# them apart.
check "a bad --repo exits nonzero"              '[ "$RC" -ne 0 ]'
check "a bad --repo is refused, not redirected" '[ ! -e "$launcher/.oma-lab/failures.jsonl" ]'

# capsule resolves --config/--output against the repo, not the caller's cwd.
# It recorded "missing:" for a file that was sitting in the target all along.
mkdir -p "$target/out"; printf 'weights\n' > "$target/out/model.txt"
( cd "$TMP" && bash "$OMA_LAB" capsule save --repo "$target" --output out/model.txt --note e2e ) >/dev/null 2>&1
check "capsule --repo fingerprints the target's artifact" \
      '! grep -q "missing:out/model.txt" "$target/.oma-lab/capsules.jsonl"'
# ...and still reports a genuinely absent file as missing, so the assertion
# above cannot be satisfied by dropping the check altogether.
( cd "$TMP" && bash "$OMA_LAB" capsule save --repo "$target" --output out/ghost.txt --note e2e ) >/dev/null 2>&1
check "capsule still reports a truly absent artifact as missing" \
      'grep -q "missing:out/ghost.txt" "$target/.oma-lab/capsules.jsonl"'

# --- a write that cannot happen must not report success ----------------------
# root ignores the write bit, so the setup would not actually block anything and
# the assertion would pass for the wrong reason. Skip rather than lie.
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP  unwritable-repo checks (running as root; chmod u-w has no effect)"
else
  blocked="$TMP/blocked"; mkdir -p "$blocked"
  (cd "$blocked" && git init -q .)
  chmod u-w "$blocked"
  blocked_out="$( cd "$blocked" && bash "$OMA_LAB" board claim --id nope 2>&1 )"
  blocked_rc=$?
  chmod u+w "$blocked"
  check "an unwritable repo fails loudly" '[ "'"$blocked_rc"'" -ne 0 ]'
  # Nonzero alone is satisfied by any unrelated error — an argument-parsing
  # slip would pass while the write silently still succeeded elsewhere.
  check "and it names the write it could not do" \
        'printf "%s" "'"$blocked_out"'" | grep -qE "cannot (write|create)"'

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
