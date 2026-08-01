#!/usr/bin/env bash
# What data produced this number, and is the split still the split you think?
#
#   oma-lab data register --name N --split LABEL=FILE... [--id-column C] [--key-column K]...
#   oma-lab data check    --name N        recompute and compare against the last registration
#   oma-lab data leakage  --name N        do the splits share ids, or share a key's values?
#   oma-lab data list
#
# FILE is relative to the repo root, not to where you are standing.
#
# The ledger records commit, dirty tree and metrics, but datasets are large and
# gitignored, so a commit hash is blind to them by construction: "which dataset
# version produced this checkpoint" is otherwise unanswerable. Rows carry the
# current run id, so a registration joins to the run that consumed it.
#
# A file hash alone is not enough for the failure that matters here. Permute
# which scaffold each molecule belongs to and the file's id set, the key's value
# set, and the row count are all unchanged while the experiment is now measuring
# something else. So each key column also gets a hash over the sorted id->value
# PAIRS, which is what actually pins an assignment.
#
# leakage is fail-closed: a missing file or a missing key column exits 2 rather
# than reporting clean. A gate that passes by skipping is worse than no gate.
set -uo pipefail

# shellcheck disable=SC1091
. "${LAB_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}/common.sh"

data_usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
    "$(readlink -f "${BASH_SOURCE[0]}")"
}

verb="${1:-}"; shift || true

NAME="" ID_COLUMN="id"
SPLITS=() KEY_COLUMNS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name|--id-column|--split|--key-column|--repo)
      [ $# -ge 2 ] || lab_die "$1 needs a value"
      case "$1" in
        --name)       NAME="$2" ;;
        # Column names are stored comma-joined, so one containing a comma would
        # come back as two columns that happen to exist and quietly fingerprint
        # the wrong thing. Refusing is honest; the CSV would need a quoted
        # header for this to be legal in the first place.
        --id-column)  case "$2" in *,*) lab_die "column name cannot contain a comma: $2" ;; esac
                      ID_COLUMN="$2" ;;
        --key-column) case "$2" in *,*) lab_die "column name cannot contain a comma: $2" ;; esac
                      KEY_COLUMNS+=("$2") ;;
        --split)      SPLITS+=("$2") ;;
        --repo)       LAB_ROOT="$(cd "$2" && pwd -P)" || lab_die "no such repo: $2"
                      export LAB_ROOT ;;
      esac
      shift 2 ;;
    -h|--help) data_usage; exit 0 ;;
    *) lab_die "unknown option: $1" ;;
  esac
done

need_name() { [ -n "$NAME" ] || lab_die "$verb requires --name"; }

# Split paths are interpreted relative to the REPO ROOT, never to the caller's
# cwd, and the root is pinned before anything reads it. Otherwise a path stored
# by `register` run from the repo top is unreadable to `check` run from a
# subdirectory or from a Slurm launcher with --repo, which is the same split
# containment bug `run` already had. `run` cds to the root for the same reason.
LAB_ROOT="${LAB_ROOT:-$(lab_repo_root)}"
export LAB_ROOT
cd "$LAB_ROOT" || lab_die "cannot enter repo root: $LAB_ROOT"

# Fingerprint every split. Emits one JSON object keyed by split label.
#
# Holds the id and key columns in memory, not whole rows: the sorted order the
# pair hash needs cannot be produced by a single streaming pass, but the columns
# are a small fraction of a wide feature table. A dataset large enough for even
# that to hurt needs an external sort, which is not what this is for.
fingerprint() {
  python3 - "$ID_COLUMN" "$(printf '%s\n' "${KEY_COLUMNS[@]+"${KEY_COLUMNS[@]}"}" | paste -sd, -)" \
    "${SPLITS[@]+"${SPLITS[@]}"}" <<'PY'
import csv, hashlib, json, sys

id_col = sys.argv[1]
key_cols = [k for k in sys.argv[2].split(",") if k]
out = {}

def sha(parts):
    h = hashlib.sha256()
    for p in parts:
        h.update(p.encode("utf-8")); h.update(b"\n")
    return h.hexdigest()[:16]

for spec in sys.argv[3:]:
    if "=" not in spec:
        sys.stderr.write("lab: --split needs LABEL=FILE, got %r\n" % spec); sys.exit(2)
    label, path = spec.split("=", 1)
    try:
        # utf-8-sig, not utf-8: pandas writes a BOM whenever it is told
        # encoding="utf-8-sig", and the BOM binds to the first header cell, so
        # the id column reads as "﻿id" and every split fails with "no id
        # column" naming a column that is plainly there. No-op without a BOM.
        fh = open(path, newline="", encoding="utf-8-sig")
    except OSError as e:
        sys.stderr.write("lab: cannot read split %s: %s\n" % (label, e)); sys.exit(2)
    with fh:
        rd = csv.DictReader(fh)
        cols = rd.fieldnames or []
        # DictReader keeps the LAST value for a repeated header, so a file with
        # two "id" columns fingerprints the second one without a word. A
        # fingerprint nobody can tell is of the wrong column is worse than none.
        dupes = sorted({c for c in cols if cols.count(c) > 1})
        if dupes:
            sys.stderr.write("lab: split %s has duplicate columns: %s\n"
                             % (label, ",".join(dupes))); sys.exit(2)
        if id_col not in cols:
            sys.stderr.write("lab: split %s has no id column %r (has: %s)\n"
                             % (label, id_col, ",".join(cols))); sys.exit(2)
        for k in key_cols:
            if k not in cols:
                sys.stderr.write("lab: split %s has no key column %r (has: %s)\n"
                                 % (label, k, ",".join(cols))); sys.exit(2)
        ids, keyed, n = [], {k: [] for k in key_cols}, 0
        for row in rd:
            n += 1
            ids.append(row[id_col] or "")
            for k in key_cols:
                keyed[k].append("%s\t%s" % (row[id_col] or "", row[k] or ""))
    # A split with a header and no rows is a failed export, not a split — and
    # left alone it is a false green downstream: `leakage` would report it
    # disjoint from everything, which is true and useless, and reads as a
    # clean bill of health for a split that contains nothing.
    if n == 0:
        sys.stderr.write("lab: split %s (%s) has no rows\n" % (label, path)); sys.exit(2)
    entry = {"rows": n, "ids": sha(sorted(ids)), "path": path}
    for k in key_cols:
        entry[k] = {"pairs": sha(sorted(keyed[k])),
                    "values": sha(sorted({p.split("\t", 1)[1] for p in keyed[k]}))}
    out[label] = entry
print(json.dumps(out, sort_keys=True))
PY
}

# Last registration wins, the same idiom board and fail already use.
last_row() {
  lab_jsonl_query "$(lab_state_dir)/datasets.jsonl" '
name = args[0]
# str(): lab_json_obj coerces a numeric-looking value to a number unless the key
# is on its identifier list, and "name" is not — a dataset called 2024 comes back
# as int and would never match the string we are looking for.
hits = [r for r in rows if str(r.get("name")) == name]
print(json.dumps(hits[-1]) if hits else "")
' "$NAME"
}

case "$verb" in
  register)
    need_name
    [ "${#SPLITS[@]}" -gt 0 ] || lab_die "register requires at least one --split LABEL=FILE"
    fp="$(fingerprint)" || exit $?
    lab_ensure_gitignore
    lab_append_jsonl "$(lab_state_dir)/datasets.jsonl" "$(lab_json_obj \
      ts "$(lab_now)" name "$NAME" id_column "$ID_COLUMN" \
      key_columns "$(printf '%s\n' "${KEY_COLUMNS[@]+"${KEY_COLUMNS[@]}"}" | paste -sd, -)" \
      splits "$fp" run_id "$(lab_current_run_id || printf '')" \
      commit "$(lab_git_commit)" git_state "$(lab_git_commit | cut -c1-12):$(lab_diff_hash)" \
      repo "$LAB_ROOT")"
    printf 'data: registered %s (%s split(s))\n' "$NAME" "${#SPLITS[@]}"
    ;;

  check)
    need_name
    prev="$(last_row)"
    [ -n "$prev" ] || lab_die "no registration named $NAME"
    # Re-run against the paths and columns recorded, not against whatever the
    # caller passed this time — otherwise check compares a thing to itself.
    eval "$(printf '%s' "$prev" | python3 -c '
import json, shlex, sys
r = json.load(sys.stdin)
sp = json.loads(r.get("splits") or "{}")
print("ID_COLUMN=%s" % shlex.quote(r.get("id_column") or "id"))
print("KEY_COLUMNS=(%s)" % " ".join(shlex.quote(k) for k in (r.get("key_columns") or "").split(",") if k))
print("SPLITS=(%s)" % " ".join(shlex.quote("%s=%s" % (l, v["path"])) for l, v in sorted(sp.items())))
')"
    now="$(fingerprint)" || exit $?
    printf '%s\n%s\n' "$prev" "$now" | python3 -c '
import json, sys
prev, now = sys.stdin.read().split("\n")[:2]
old = json.loads(json.loads(prev).get("splits") or "{}")
new = json.loads(now)
drift = 0
# The label sets cannot diverge: `new` is fingerprinted from the paths recorded
# in `old`, and a path that no longer reads exits 2 before reaching here. A
# "split missing" branch would be unreachable code that reads like a live guard.
for label in sorted(old):
    a, b = old[label], new[label]
    for k in sorted(set(a) | set(b)):
        if k == "path": continue
        if a.get(k) != b.get(k):
            what = "%s pairs" % k if isinstance(a.get(k), dict) else k
            print("DRIFT %s: %s changed" % (label, what)); drift = 1
    if a == b: print("ok %s: unchanged (%s rows)" % (label, b["rows"]))
sys.exit(1 if drift else 0)
'
    ;;

  leakage)
    need_name
    prev="$(last_row)"
    [ -n "$prev" ] || lab_die "no registration named $NAME"
    printf '%s' "$prev" | python3 -c '
import csv, json, sys
r = json.load(sys.stdin)
sp = json.loads(r.get("splits") or "{}")
id_col = r.get("id_column") or "id"
keys = [k for k in (r.get("key_columns") or "").split(",") if k]

def col(path, name):
    try: fh = open(path, newline="", encoding="utf-8")
    except OSError as e:
        sys.stderr.write("lab: cannot read %s: %s\n" % (path, e)); sys.exit(2)
    with fh:
        rd = csv.DictReader(fh)
        if name not in (rd.fieldnames or []):
            sys.stderr.write("lab: %s has no column %r\n" % (path, name)); sys.exit(2)
        return {row[name] or "" for row in rd}

labels = sorted(sp)
# One split has no pairs to compare, so the loop below never runs and the
# command exits 0 having printed nothing — which any caller reads as "no
# leakage". Same rule as a missing file: not looking is not a pass.
if len(labels) < 2:
    sys.stderr.write("lab: %s has %d split(s) — nothing to compare\n" % (r.get("name"), len(labels)))
    sys.exit(2)
bad = 0
for i in range(len(labels)):
    for j in range(i + 1, len(labels)):
        a, b = labels[i], labels[j]
        for name in [id_col] + keys:
            shared = col(sp[a]["path"], name) & col(sp[b]["path"], name)
            tag = "ids" if name == id_col else "key %s" % name
            if shared:
                ex = ", ".join(sorted(shared)[:3])
                print("LEAKAGE[%s] %s n %s: %d shared (%s)" % (tag, a, b, len(shared), ex))
                bad = 1
            else:
                print("ok [%s] %s n %s: disjoint" % (tag, a, b))
sys.exit(1 if bad else 0)
'
    ;;

  list)
    lab_jsonl_query "$(lab_state_dir)/datasets.jsonl" '
seen = {}
for r in rows: seen[str(r.get("name"))] = r
for name, r in sorted(seen.items()):
    sp = json.loads(r.get("splits") or "{}")
    print("%s  %-20s %s  run=%s" % (r.get("ts","?"), name,
          ",".join("%s:%s" % (k, v["rows"]) for k, v in sorted(sp.items())),
          r.get("run_id") or "-"))
print("(%d dataset(s))" % len(seen))
'
    ;;

  ""|-h|--help|help) data_usage ;;
  *) lab_die "unknown verb: $verb" ;;
esac
