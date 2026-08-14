#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# One sandbox root for every step, removed once. Previously each step made its
# own mktemp dir and re-registered an EXIT trap, so the later trap replaced the
# earlier one; and step [5] wrote to a fixed /tmp path that collided between
# concurrent runs and was never cleaned.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/oh-my-agent-env-smoke.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Keep sub-tools off the real user environment. HOME alone is not enough:
# anything honouring XDG or writing a git config still reaches ~/.config,
# ~/.cache and ~/.gitconfig.
export XDG_CONFIG_HOME="$TMP/xdg-config"
export XDG_CACHE_HOME="$TMP/xdg-cache"
export XDG_DATA_HOME="$TMP/xdg-data"
export TMPDIR="$TMP/runtime"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$TMPDIR"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "[1] shell syntax"
bash -n "$ROOT/setup.sh" "$ROOT/lib/common.sh" "$ROOT/lib/sync.sh" "$ROOT"/lib/sync/*.sh "$ROOT/lib/doctor.sh" "$ROOT"/lib/doctor/*.sh

echo "[2] required sync domains"
for f in \
  "$ROOT/lib/sync/core.sh" \
  "$ROOT/lib/sync/rules.sh" \
  "$ROOT/lib/sync/skills.sh" \
  "$ROOT/lib/sync/external-tools.sh" \
  "$ROOT/lib/sync/plugins-mcp.sh" \
  "$ROOT/lib/sync/frameworks.sh"; do
  test -f "$f"
done

echo "[3] required doctor domains"
for f in \
  "$ROOT/lib/doctor/local-prereqs.sh" \
  "$ROOT/lib/doctor/claude.sh" \
  "$ROOT/lib/doctor/codex-integrity.sh" \
  "$ROOT/lib/doctor/lazycodex.sh" \
  "$ROOT/lib/doctor/agent-mcp.sh" \
  "$ROOT/lib/doctor/frameworks.sh" \
  "$ROOT/lib/doctor/main.sh"; do
  test -f "$f"
done

echo "[4] public command functions"
grep -q '^cmd_sync()' "$ROOT/lib/sync.sh"
grep -q '^cmd_doctor()' "$ROOT/lib/doctor/main.sh"
grep -q '^sync_external_tools()' "$ROOT/lib/sync/external-tools.sh"
grep -q '^sync_plugins_mcp()' "$ROOT/lib/sync/plugins-mcp.sh"
grep -q '^sync_agent_mcp_frameworks()' "$ROOT/lib/sync/frameworks.sh"
grep -q '^doctor_lazycodex()' "$ROOT/lib/doctor/lazycodex.sh"
grep -q '^doctor_agent_mcp_surfaces()' "$ROOT/lib/doctor/agent-mcp.sh"

echo "[5] isolated HOME validate"
tmp_home="$TMP/home"; mkdir -p "$tmp_home"
HOME="$tmp_home" bash "$ROOT/setup.sh" validate >"$TMP/validate.out"
grep -q '=== oh-my-agent-env validate ===' "$TMP/validate.out"

echo "[6] oma subcommand isolated smoke (stubbed bunx, no network)"
oma_tmp="$TMP/oma"
stub_bin="$oma_tmp/bin"; mkdir -p "$stub_bin" "$oma_tmp/home"
# offline stub: oma install just materializes .agents/ in the project cwd
cat > "$stub_bin/bunx" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$PWD/.agents"
echo "stub: oma installed"
STUB
chmod +x "$stub_bin/bunx"
oma_proj="$oma_tmp/proj"; mkdir -p "$oma_proj"
# OMA_SKIP_DEPS=1 keeps this hermetic/offline: skip the [0] oma-CLI/serena
# global install step (bun add -g / uv tool install would hit the network).
run_oma() { OMA_SKIP_DEPS=1 PATH="$stub_bin:$PATH" HOME="$oma_tmp/home" bash "$ROOT/setup.sh" oma "$oma_proj" >/dev/null 2>&1; }
run_oma
# a) oma-config.yaml overlaid byte-identical to the tracked template (managed)
cmp -s "$oma_proj/.agents/oma-config.yaml" "$ROOT/templates/oma/oma-config.yaml"
# b) statusLine pinned in settings.local.json -> our unified script
python3 -c "import json,sys; d=json.load(open('$oma_proj/.claude/settings.local.json')); sys.exit(0 if d.get('statusLine',{}).get('command','').endswith('my-statusline.mjs') else 1)"
# c) idempotent: a second run leaves both outputs byte-stable
cp "$oma_proj/.claude/settings.local.json" "$oma_tmp/sl1"
run_oma
cmp -s "$oma_proj/.claude/settings.local.json" "$oma_tmp/sl1"
cmp -s "$oma_proj/.agents/oma-config.yaml" "$ROOT/templates/oma/oma-config.yaml"

echo "[7] Claude hook manifest contract"
# The defect this step exists to catch: runtimes/claude/hooks/ once held six
# hooks while only three were wired into settings.json, so three shipped as
# silent dead code on any machine that had not been hand-edited. Nothing failed.
manifest="$ROOT/runtimes/claude/hooks/manifest.json"
test -f "$manifest" || fail "hook manifest missing: $manifest"
python3 -m json.tool "$manifest" >/dev/null || fail "hook manifest is not valid JSON"

# a) every manifest entry names a script that actually ships
python3 - "$manifest" "$ROOT/runtimes/claude/hooks" <<'PY' || fail "manifest lists a script that does not exist"
import json, sys
from pathlib import Path
manifest, hooks_dir = Path(sys.argv[1]), Path(sys.argv[2])
missing = [h["script"] for h in json.loads(manifest.read_text())["hooks"]
           if not (hooks_dir / h["script"]).is_file()]
if missing:
    print("missing:", ", ".join(missing)); sys.exit(1)
PY

# b) every shipped non-test hook is claimed by the manifest — this is the
#    direction that actually catches "added a hook, forgot to register it"
python3 - "$manifest" "$ROOT/runtimes/claude/hooks" <<'PY' || fail "a shipped hook is absent from the manifest"
import json, sys
from pathlib import Path
manifest, hooks_dir = Path(sys.argv[1]), Path(sys.argv[2])
listed = {h["script"] for h in json.loads(manifest.read_text())["hooks"]}
shipped = {p.name for p in hooks_dir.glob("*.js") if not p.name.startswith("test-")}
unclaimed = sorted(shipped - listed)
if unclaimed:
    print("shipped but unregistered:", ", ".join(unclaimed)); sys.exit(1)
if any(s.startswith("test-") for s in listed):
    print("manifest must not list test fixtures"); sys.exit(1)
PY

# c) reconcile against a settings.json holding foreign hooks: ours all land,
#    foreign survive untouched, and a second run is a byte-identical no-op
hook_cfg="$TMP/hookcfg"; mkdir -p "$hook_cfg/hooks"
cat > "$hook_cfg/settings.json" <<JSON
{"statusLine":{"command":"keep-me"},
 "autoCompactWindow":400000,
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}],
          "SessionStart":[{"hooks":[{"type":"command","command":"$hook_cfg/hooks/foreign-tool.mjs"}]}]}}
JSON
(
  SCRIPT_DIR="$ROOT" CONFIG_DIR="$hook_cfg"
  export SCRIPT_DIR CONFIG_DIR
  log_and_print() { echo "$@"; }
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh" 2>/dev/null || true
  ensure_rules_enforcement_hooks >/dev/null
  cp "$hook_cfg/settings.json" "$TMP/hooks-after1.json"
  ensure_rules_enforcement_hooks >/dev/null
) || fail "ensure_rules_enforcement_hooks errored"
cmp -s "$TMP/hooks-after1.json" "$hook_cfg/settings.json" \
  || fail "hook reconcile is not idempotent"
python3 - "$manifest" "$hook_cfg/settings.json" <<'PY' || fail "hook reconcile produced wrong settings.json"
import json, re, sys
from pathlib import Path
manifest, settings = Path(sys.argv[1]), Path(sys.argv[2])
d = json.loads(settings.read_text())
cmds = [x.get("command", "") for arr in d["hooks"].values() for g in arr for x in g.get("hooks", [])]
# Count on the full installed path, the same key ensure_rules_enforcement_hooks
# uses. A bare basename over-counts whenever one script's name is a substring of
# another's: "compact-gate" appears inside "precompact-gate.sh", so the CLI hook
# looked registered twice and a correct manifest failed this check.
hooks_dir = settings.parent / "hooks"
for h in json.loads(manifest.read_text())["hooks"]:
    needle = f"{hooks_dir}/{h['script']}"
    if sum(needle in c for c in cmds) != 1:
        print(f"{h['script']} not registered exactly once"); sys.exit(1)
if not any("rtk hook claude" == c for c in cmds): print("foreign rtk hook lost"); sys.exit(1)
if not any("foreign-tool.mjs" in c for c in cmds): print("foreign SessionStart hook lost"); sys.exit(1)
if d.get("statusLine", {}).get("command") != "keep-me": print("non-hook key clobbered"); sys.exit(1)

# A registered hook can still be inert. The compact gate is sized against
# autoCompactWindow, which lives in settings.json and not in any hook file, so
# shipping the hook without the option left every machine but the one it was
# tuned on compacting at the old point. Assert the option travels with the hook,
# and that the pair still satisfies the invariant it exists for: the gate's
# ceiling must sit ABOVE the compaction point, or the gate hits
# ceiling-reached on every call and allows compaction it was meant to defer.
want = json.loads(manifest.read_text()).get("settings", {})
if "autoCompactWindow" not in want:
    print("manifest no longer ships autoCompactWindow"); sys.exit(1)
for key, value in want.items():
    if d.get(key) != value:
        print(f"{key} not reconciled: {d.get(key)!r} != {value!r}"); sys.exit(1)
ceilings = [int(m) for c in cmds for m in re.findall(r"COMPACT_HARD_CEILING=(\d+)", c)]
if len(ceilings) != 1: print(f"expected one compact ceiling, found {ceilings}"); sys.exit(1)
if ceilings[0] <= d["autoCompactWindow"]:
    print(f"ceiling {ceilings[0]} is not above compaction point {d['autoCompactWindow']}"); sys.exit(1)
PY

# d) cross-review regressions: a foreign command that merely MENTIONS one of our
#    basenames, and an entry for the test fixture, must both survive. Matching
#    "in our hooks dir" AND "mentions our basename" separately deleted both.
hk2="$TMP/hookcfg2"; mkdir -p "$hk2/hooks"
cat > "$hk2/settings.json" <<JSON
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node \\"$hk2/hooks/foreign-wrapper.mjs\\" --note bash-size-guard.js"}]}],
          "Stop":[{"hooks":[{"type":"command","command":"node \\"$hk2/hooks/test-pre-edit-gate.js\\""}]}]}}
JSON
(
  SCRIPT_DIR="$ROOT" CONFIG_DIR="$hk2"; export SCRIPT_DIR CONFIG_DIR
  log_and_print() { echo "$@"; }
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh" 2>/dev/null || true
  ensure_rules_enforcement_hooks >/dev/null
)
grep -q 'foreign-wrapper.mjs'   "$hk2/settings.json" || fail "reconcile deleted a foreign hook"
grep -q 'test-pre-edit-gate.js' "$hk2/settings.json" || fail "reconcile pruned the test fixture entry"

echo "[8] managed-block assembly preserves user content"
# The defect this step exists to catch: global rule assembly used to be a
# truncating `> "$target"` over ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md and
# ~/.gemini/GEMINI.md, so anything the user added there died on the next sync.
mb="$TMP/mb"; mkdir -p "$mb"
printf 'BODY v1\n' > "$mb/body1"
printf 'BODY v2\n' > "$mb/body2"
(
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  log_and_print() { echo "$@"; }
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh" 2>/dev/null || true

  write_managed_block "$mb/t.md" "$mb/body1"
  cp "$mb/t.md" "$mb/snap1"
  write_managed_block "$mb/t.md" "$mb/body1"
  cmp -s "$mb/snap1" "$mb/t.md" || { echo "managed block not idempotent"; exit 1; }

  printf '\n## user note\nkeep this\n' >> "$mb/t.md"
  write_managed_block "$mb/t.md" "$mb/body2"
  grep -q 'keep this' "$mb/t.md" || { echo "user content outside markers destroyed"; exit 1; }
  grep -q 'BODY v2'   "$mb/t.md" || { echo "managed body not refreshed"; exit 1; }
  ! grep -q 'BODY v1' "$mb/t.md" || { echo "stale managed body left behind"; exit 1; }

  printf 'legacy user content\n' > "$mb/legacy.md"
  write_managed_block "$mb/legacy.md" "$mb/body1" >/dev/null
  ls "$mb"/legacy.md.bak.* >/dev/null 2>&1 || { echo "pre-marker file not backed up"; exit 1; }

  # A file carrying only one marker is malformed, not legacy. Adopting it moves
  # the visible content into a backup and leaves the live file holding just the
  # generated block, so refuse and keep it byte-identical instead.
  printf '# mine\n%s\nvisible to the user\n' "$OMA_BLOCK_BEGIN" > "$mb/half.md"
  cp "$mb/half.md" "$mb/half.before"
  rc=0; write_managed_block "$mb/half.md" "$mb/body2" >/dev/null || rc=$?
  cmp -s "$mb/half.before" "$mb/half.md" || { echo "half-marked file was rewritten"; exit 1; }

  # Refusing to write is right; refusing SILENTLY is what let a sync report
  # success with one CLI left on the previous rules. The status is the only
  # thing a caller can act on, so it is asserted here rather than assumed.
  #
  # `set -e` is suppressed inside this subshell — the whole `( ... )` is the
  # left operand of `|| fail` — so a bare call would swallow the status and
  # this check would pass no matter what the function returned. Capture it.
  [ "$rc" -eq 3 ] || { echo "half-marked refusal reported rc=$rc, want 3"; exit 1; }

  rc=0; write_managed_block "$mb/t.md" "$mb/body2" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || { echo "an up-to-date target reported rc=$rc, want 0"; exit 1; }

  # A body carrying a marker would make the next run split in the wrong place.
  printf 'x %s x\n' "$OMA_BLOCK_BEGIN" > "$mb/body-marked"
  rc=0; write_managed_block "$mb/fresh.md" "$mb/body-marked" >/dev/null || rc=$?
  [ "$rc" -eq 3 ] || { echo "marker-in-body refusal reported rc=$rc, want 3"; exit 1; }
) || fail "managed-block assembly regressed"

echo "[9] Obsidian work-journal (fake vault, never the real one)"
# Runs entirely against $TMP. The real vault is Syncthing-backed and holds the
# user's notes; a test must never be one typo away from writing into it.
jv="$TMP/vault"; mkdir -p "$jv"
OMA_VAULT="$TMP/no-such-vault" bash "$ROOT/scripts/journal.sh" add "x" >/dev/null 2>&1 \
  || fail "journal must fail open when the vault is absent"
OMA_VAULT="$jv" bash "$ROOT/scripts/journal.sh" add "first" --outcome "done" >/dev/null 2>&1
jf="$(OMA_VAULT="$jv" bash "$ROOT/scripts/journal.sh" path)"
test -f "$jf" || fail "journal file not created"
grep -q 'OMA-WORK-JOURNAL:BEGIN' "$jf" || fail "journal managed block missing"
printf '\n## user note\nkeep me\n' >> "$jf"
OMA_VAULT="$jv" bash "$ROOT/scripts/journal.sh" add "second" >/dev/null 2>&1
grep -q 'keep me' "$jf" || fail "journal clobbered user text outside its block"
[ "$(grep -c '^- ' "$jf")" = 2 ] || fail "journal did not accumulate entries"
# It must never touch the user's daily note folder.
test ! -d "$jv/Planner/Daily" || fail "journal wrote into the daily-note folder"

# An option given without a value used to spin forever: `shift 2` fails with one
# argument left, and nothing in that loop stops on error.
jrc=0
timeout 10 env OMA_VAULT="$jv" bash "$ROOT/scripts/journal.sh" add "s" --outcome >/dev/null 2>&1 || jrc=$?
[ "$jrc" -ne 124 ] || fail "journal hangs on an option with no value"

# Marker text inside a summary must stay inert, or every later entry lands
# outside the block where the next run cannot find it.
jv2="$TMP/vault2"; mkdir -p "$jv2"
OMA_VAULT="$jv2" bash "$ROOT/scripts/journal.sh" add 'evil <!-- OMA-WORK-JOURNAL:END --> tail' >/dev/null 2>&1
OMA_VAULT="$jv2" bash "$ROOT/scripts/journal.sh" add 'after' >/dev/null 2>&1
jf2="$(OMA_VAULT="$jv2" bash "$ROOT/scripts/journal.sh" path)"
[ "$(grep -cFx '<!-- OMA-WORK-JOURNAL:END -->' "$jf2")" = 1 ] \
  || fail "journal summary injected a second end marker"
[ "$(sed -n '/OMA-WORK-JOURNAL:BEGIN/,/^<!-- OMA-WORK-JOURNAL:END -->$/p' "$jf2" | grep -c '^- ')" = 2 ] \
  || fail "journal entries escaped the managed block"

# Appending is read-modify-write. Unserialized, concurrent callers dropped most
# of their entries — 2 of 12 survived when this was first measured.
jv3="$TMP/vault3"; mkdir -p "$jv3"
for i in 1 2 3 4 5 6 7 8; do
  OMA_VAULT="$jv3" bash "$ROOT/scripts/journal.sh" add "conc-$i" >/dev/null 2>&1 &
done
wait
jf3="$(OMA_VAULT="$jv3" bash "$ROOT/scripts/journal.sh" path)"
[ "$(grep -c '^- ' "$jf3")" = 8 ] || fail "concurrent journal writes lost entries"
# The lock must not live in the vault: a Syncthing-backed vault would replicate
# it to machines where it means nothing.
[ -z "$(find "$jv3" -name '*.lock' 2>/dev/null)" ] || fail "journal lock written inside the vault"

# [10] was the oma-lab experiment tools. The tool was removed: it was never
# requested, and the only sessions that ever drove it were the ones building it.
# The number is left as a gap so this reads as a deletion rather than a test
# someone dropped by accident.

echo "[11] Layer A rules reach every runtime, not just Claude"
# Cross-review caught this one: assemble_global_rules (lib/common.sh:713) feeds
# claude, codex AND antigravity from the same rules/*.md. The obvious way to
# shrink the resident file — move a rule module into an on-demand skill — is
# safe only if that skill ships to all three. Move it Claude-only and the other
# two silently lose the rule, with nothing failing to say so.
#
# The invariant is therefore parity, not size: every section heading in Layer A
# must be reachable from each runtime's global instruction file. Rewording a
# rule keeps this green; quietly dropping one for two of three CLIs does not.
#
# The baseline is checked in (tests/fixtures/layer-a-sections.txt) rather than
# derived from rules/*.md. Deriving it makes the check a tautology: emptying a
# module also empties the expectation, so the first version of this step passed
# its own negative control. Retiring a section now means editing the fixture on
# purpose.
#
# Both directions are asserted, because a checked-in baseline has its own way to
# rot. The first fixture held 11 of the 16 headings: it was generated with a
# bare `sort -u`, and under en_US.UTF-8 collation that considers several of these
# Korean headings equal and silently drops them. The check meant to catch that
# used the same pipeline, so it agreed. Comparison is done in python here for the
# same reason — this must not depend on the caller's locale.
ra="$TMP/rules-assemble"; mkdir -p "$ra"
(
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  CONFIG_DIR="$ra/claude"; CODEX_DIR="$ra/codex"; GEMINI_DIR="$ra/gemini"
  # log() appends to $LOG_FILE (lib/common.sh:15). Sourcing overrides any stub
  # defined here, so point the real variable at the sandbox instead — an empty
  # $LOG_FILE makes every log line a failed redirect, which under `set -e` kills
  # the assembly before it writes anything.
  LOG_FILE="$ra/sync.log"
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh" 2>/dev/null || true
  assemble_global_rules >/dev/null 2>&1
) || { echo "assembly failed"; fail "Layer A rules are no longer CLI-agnostic"; }

python3 - "$ROOT" "$ra" <<'PY' || fail "Layer A rules are no longer CLI-agnostic"
import glob, os, sys
root, ra = sys.argv[1], sys.argv[2]

fixture = [l.rstrip("\n") for l in
           open(os.path.join(root, "tests/fixtures/layer-a-sections.txt"), encoding="utf-8")
           if l.startswith("## ")]
current = {l.rstrip("\n") for p in sorted(glob.glob(os.path.join(root, "rules/*.md")))
           for l in open(p, encoding="utf-8") if l.startswith("## ")}

bad = False
# 1. the baseline must still cover Layer A — a new section that never reaches the
#    fixture is a rule nothing will ever check
for h in sorted(current - set(fixture)):
    print(f"heading absent from the fixture baseline: {h}"); bad = True

# 2. every baseline heading must be reachable from all three runtimes
for target in ("claude/CLAUDE.md", "codex/AGENTS.md", "gemini/GEMINI.md"):
    path = os.path.join(ra, target)
    if not os.path.isfile(path):
        print(f"not assembled: {target}"); bad = True; continue
    body = open(path, encoding="utf-8").read().split("\n")
    for h in fixture:
        if h not in body:
            print(f"Layer A heading missing from {os.path.basename(target)}: {h}"); bad = True
sys.exit(1 if bad else 0)
PY

echo "[11b] a partial assembly is reported, not silently survived"
# Step [11] proves the rules REACH all three runtimes; it cannot prove they are
# CURRENT there. It assembles into an empty sandbox every time, so the one thing
# it can never observe is the production failure: a target that already exists,
# is skipped this run, and keeps serving the previous rules. Reproduced before
# the fix — sync returned 0, printed [OK] for the two it wrote, and the third
# CLI stayed on stale text with nothing to say so.
#
# Body-only drift is the case that matters. Headings are what step [11] checks,
# so a divergence that moves no heading is exactly the one already covered
# nowhere.
pa="$TMP/partial"; mkdir -p "$pa/src"
cp -r "$ROOT/rules" "$ROOT/runtimes" "$ROOT/lib" "$pa/src/"

pa_assemble() {
  ( SCRIPT_DIR="$pa/src"; export SCRIPT_DIR
    CONFIG_DIR="$pa/claude"; CODEX_DIR="$pa/codex"; GEMINI_DIR="$pa/gemini"
    LOG_FILE="$pa/sync.log"
    # shellcheck disable=SC1091
    source "$pa/src/lib/common.sh" 2>/dev/null || true
    # Kept, not discarded. A nonzero status only says something went wrong; the
    # operator's next move depends on WHICH runtime is behind, and a bare
    # `return 1` satisfies an rc-only assertion while saying nothing at all.
    assemble_global_rules > "$pa/out.txt" 2>&1 )
}

rc=0; pa_assemble || rc=$?
[ "$rc" -eq 0 ] || fail "[11b] a complete assembly must report success (got $rc)"

# Change a rule's BODY only, and drop one runtime's Layer B.
printf '\nSENTINEL-BODY-DRIFT\n' >> "$pa/src/rules/00-core.md"
mv "$pa/src/runtimes/antigravity/tools.md" "$pa/src/tools.md.parked"
rc=0; pa_assemble || rc=$?
[ "$rc" -ne 0 ] || fail "[11b] a partial assembly reported success — the drift is silent again"

# A nonzero status alone leaves the operator with nowhere to go. Cross-review's
# point: swap the whole branch for a bare `return 1` and every assertion above
# still passes, while the one fact worth having — which runtime is behind —
# disappears. So assert the diagnostic, and assert it does NOT indict the two
# runtimes that are current, or "name the stale CLI" degrades into "name all
# three", which is the same as naming none.
grep -q 'not updated:.*antigravity' "$pa/out.txt" \
  || fail "[11b] the failure did not name the runtime that stayed behind"
! grep -q 'not updated:.*claude' "$pa/out.txt" \
  || fail "[11b] the failure indicted a runtime that was actually updated"

# and the failure named a target that is genuinely behind, not a guess
grep -q 'SENTINEL-BODY-DRIFT' "$pa/claude/CLAUDE.md" \
  || fail "[11b] the runtimes that were written did not get the change"
! grep -q 'SENTINEL-BODY-DRIFT' "$pa/gemini/GEMINI.md" \
  || fail "[11b] fixture is wrong: the skipped runtime received the change anyway"

# Negative control. Without this the check above passes for a function that
# fails unconditionally, which would be worse than the bug it replaced.
mv "$pa/src/tools.md.parked" "$pa/src/runtimes/antigravity/tools.md"
rc=0; pa_assemble || rc=$?
[ "$rc" -eq 0 ] || fail "[11b] a repaired tree still reports failure (got $rc)"
grep -q 'SENTINEL-BODY-DRIFT' "$pa/gemini/GEMINI.md" \
  || fail "[11b] the repaired run did not catch the skipped runtime up"

echo "[12] NPM_USER_ENV survives the bash -c it is built for"
# Cross-review's sharpest remaining point: nothing in this suite touches the
# sync paths that decide WHERE a global npm install lands. NPM_USER_ENV carries
# quotes on purpose (lib/common.sh), and shellcheck is silenced about them
# because run_with_timeout evaluates the string through `bash -c`. If that
# contract ever breaks, npm falls back to the system prefix and installs land
# outside $HOME — the failure is silent and needs root to undo.
#
# So pin the contract rather than the implementation: build the prefix under a
# hostile HOME and assert the value arrives intact on the far side of a real
# `bash -c`. Both shapes are checked. A space is the case the quoting was
# written for; a single quote is the case it originally got wrong, closing the
# quoted string early and leaving the rest of the path to be parsed as code.
for np_leaf in "np dir" "np'q dir"; do
np="$TMP/$np_leaf"; mkdir -p "$np"
(
  HOME="$np"; export HOME
  LOG_FILE="$TMP/np.log"
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh" 2>/dev/null || true
  ensure_user_npm_prefix >/dev/null 2>&1

  case "$USER_NPM_PREFIX" in
    "$np"/*) ;;
    *) echo "prefix escaped HOME: $USER_NPM_PREFIX"; exit 1 ;;
  esac
  got="$(bash -c "$NPM_USER_ENV printenv npm_config_prefix")" || {
    echo "NPM_USER_ENV is not bash -c safe: $NPM_USER_ENV"; exit 1; }
  [ "$got" = "$USER_NPM_PREFIX" ] || {
    echo "prefix mangled through bash -c: got '$got' want '$USER_NPM_PREFIX'"; exit 1; }
  [ -d "$USER_NPM_PREFIX/bin" ] && [ -d "$USER_NPM_PREFIX/lib" ] || {
    echo "prefix dirs not created"; exit 1; }
) || fail "NPM_USER_ENV no longer delivers the prefix it promises (HOME=$np_leaf)"
done

# [13] A download that never happened must not read as a successful install.
# `curl ... | bash` hides a failed fetch: curl exits nonzero and writes nothing,
# bash reads empty stdin and exits 0, and the pipeline reports success. The
# caller then blames PATH shadowing for a package that was never downloaded.
# Stubbed curl, so this asserts the shell contract without touching the network.
pf="$TMP/pipefail"; mkdir -p "$pf/bin"
cat > "$pf/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect" >&2
exit 7
STUB
chmod +x "$pf/bin/curl"
(
  PATH="$pf/bin:$PATH"; export PATH
  SCRIPT_DIR="$ROOT"; export SCRIPT_DIR
  LOG_FILE="$pf/log"; STEP_TIMEOUT=20
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh" 2>/dev/null || true

  if run_with_timeout "pipefail probe" \
       "set -o pipefail; curl -fsSL http://example.invalid/i.sh | bash" >/dev/null 2>&1
  then
    echo "a failed download still reports success"; exit 1
  fi
) || fail "curl|bash install no longer propagates a failed fetch"

# The installer this protects must keep both guards; either one alone leaks.
grep -q 'set -o pipefail; \$NPM_USER_ENV curl -fsSL' "$ROOT/lib/sync/external-tools.sh" \
  || fail "codex-gemini-mcp install lost its pipefail/curl -f guard"

echo "[16] every installed hook actually runs"
# `node --check` and `bash -n` prove a hook PARSES. They say nothing about
# whether it runs: a bad require, a missing helper, a wrong path all pass every
# gate we had and then the hook dies on first invocation. Reproduced with a
# `require('module-that-does-not-exist')` in stop-todo-gate.js — node --check
# OK, doctor OK (file exists, registered), check.sh PASS, hook exit 1 and the
# gate silently stops enforcing.
#
# So drive each manifest hook the way Claude Code will, with a payload shaped
# like the real one, and require it to survive. Allowed exits are 0 and 2 only:
# 2 is a real decision (block), while a crashing interpreter gives 1 and a
# missing command gives 127.
hp="$TMP/hookprobe"; mkdir -p "$hp/home" "$hp/cwd"; : > "$hp/transcript.jsonl"
python3 - "$ROOT/runtimes/claude/hooks/manifest.json" > "$TMP/hooks.tsv" <<'PYEOF'
import json, sys
# \x1f, not tab: tab is IFS whitespace, so `read` collapses consecutive tabs and
# an empty matcher silently shifts every later field left. That is not
# hypothetical — it shipped in the first version of this step, and four hooks
# (the ones with no matcher) ran `bash -c ""` and passed. A mutation that
# should have killed the step survived it.
for h in json.loads(open(sys.argv[1]).read())["hooks"]:
    print("\x1f".join([h["event"], h["script"], h.get("matcher") or "",
                       h.get("run") or 'node "{path}"']))
PYEOF
[ -s "$TMP/hooks.tsv" ] || fail "hook manifest produced no entries to smoke"
smoked=0
while IFS=$'\x1f' read -r event script matcher template; do
  tool="${matcher%%|*}"
  [ -n "$template" ] || fail "$event:$script has no command template — the manifest table was misparsed"
  case "$event" in
    UserPromptSubmit) body='"prompt":"probe"' ;;
    PreToolUse)       body="\"tool_name\":\"$tool\",\"tool_input\":{},\"tool_use_id\":\"t\"" ;;
    PostToolUseFailure)
                      body="\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"probe\"},\"tool_use_id\":\"t\",\"error\":\"boom\",\"is_interrupt\":false" ;;
    Stop|SubagentStop) body='"stop_hook_active":false' ;;
    PreCompact)       body="\"trigger\":\"${tool:-auto}\",\"custom_instructions\":\"\"" ;;
    SessionEnd)       body='"reason":"clear"' ;;
    *)                body='"probe":true' ;;
  esac
  payload="{\"session_id\":\"smoke\",\"transcript_path\":\"$hp/transcript.jsonl\",\"cwd\":\"$hp/cwd\",\"hook_event_name\":\"$event\",$body}"
  cmd="${template//\{path\}/$ROOT/runtimes/claude/hooks/$script}"
  # HOME and COMPACT_GATE_DIR are redirected because the compact hooks keep
  # their markers under $HOME/.claude/compact-gate — running them unsandboxed
  # would clear a live session's busy marker or spend its defer budget.
  set +e
  printf '%s' "$payload" | (cd "$hp/cwd" && env HOME="$hp/home" \
    COMPACT_GATE_DIR="$hp/home/gate" timeout 20 bash -c "$cmd") \
    >"$TMP/hook.out" 2>"$TMP/hook.err"
  rc=$?
  set -e
  case "$rc" in
    0|2) ;;
    *) echo "--- stderr ---"; sed 's/^/    /' "$TMP/hook.err" >&2
       echo "--- stdout ---"; sed 's/^/    /' "$TMP/hook.out" >&2
       fail "$event:$script exited $rc — a hook that cannot run is a gate that is off" ;;
  esac
  # Deliberately no assertion on the shape of $out here. Every hook is silent
  # under a nothing-to-say payload, so a stdout check in this loop is one no
  # mutation can kill — and PreCompact's stdout is compact instructions, not
  # JSON, so "must be JSON" is wrong besides. Output shape is asserted where it
  # can actually be provoked — runtimes/claude/hooks/test-pre-edit-gate.js
  # drives payloads that force a decision.
  smoked=$((smoked+1))
done < "$TMP/hooks.tsv"
# A loop that ran fewer times than there are hooks passes for the wrong reason.
want_hooks="$(wc -l < "$TMP/hooks.tsv")"
[ "$smoked" -eq "$want_hooks" ] \
  || fail "smoked $smoked hooks but the manifest lists $want_hooks"

echo "[17] project style is decided by ML use, not by ML being mentioned"
# apply-project-template.sh feeds this answer straight into which managed block it
# writes, so a false `ml` installs ML rules into a repo with no model in it. That
# was live: over 9 real repos the old rules answered `ml` for all 9, including
# this shell harness (setup.sh names `jaxtyping`; `jax` is a substring) and
# PROject/data_utils (two commented-out `#import torch` lines).
#
# The negative fixtures are the point. `commented`, `keyword-list` and
# `mention-doc` each reproduce one of the false positives, so widening the match
# back to a bare substring fails this test rather than silently passing.
sfx="$TMP/style-fixtures"
mkdir -p "$sfx"/{manifest-only,import-only,commented,mention-doc,keyword-list,entrypoint,generic-config,empty}
printf 'numpy\ntorch==2.1.0\n'              > "$sfx/manifest-only/requirements.txt"
printf 'import os\nimport torch\n'          > "$sfx/import-only/a.py"
printf '#import torch\n#import torch.nn\n'  > "$sfx/commented/a.py"
printf '| Type Hints | jaxtyping |\n'       > "$sfx/mention-doc/setup.sh"
printf 'KEYWORDS = [\n    "torch",\n]\n'    > "$sfx/keyword-list/a.py"
: > "$sfx/entrypoint/train.py"
mkdir -p "$sfx/generic-config/configs"; : > "$sfx/generic-config/config.yaml"

# Run each case twice: once as the user has it, once with a PATH that has no rg,
# because the two branches are separate implementations of the same rule and only
# one of them was ever exercised here.
for case in manifest-only:ml import-only:ml commented:general mention-doc:general \
            keyword-list:general entrypoint:ml generic-config:general empty:general; do
  want="${case##*:}"
  got="$(bash "$ROOT/scripts/detect-project-style.sh" "$sfx/${case%%:*}")"
  [ "$got" = "$want" ] || fail "[17] ${case%%:*}: expected $want, got $got"
  got="$(env PATH=/usr/bin:/bin bash "$ROOT/scripts/detect-project-style.sh" "$sfx/${case%%:*}")"
  [ "$got" = "$want" ] || fail "[17] ${case%%:*} (no rg): expected $want, got $got"
done

echo "[18] switching base style replaces its rules instead of stacking them"
# block_content inlines the whole template rather than a pointer, so a leftover
# block is a second complete rule set. Reproduced before the fix: general then ml
# on one directory left a 151-line CLAUDE.md carrying both.
blocks_in() { grep -o 'cc-bootstrap:[a-z]*:begin' "$1" | sed 's/cc-bootstrap://;s/:begin//' | sort | tr '\n' ' '; }
apt="$ROOT/scripts/apply-project-template.sh"

t18="$TMP/style-switch"; mkdir -p "$t18"
"$apt" general "$t18" >/dev/null
"$apt" ml "$t18" >/dev/null
got="$(blocks_in "$t18/CLAUDE.md")"
[ "$got" = "ml " ] || fail "[18] general->ml left blocks: $got"

# Re-applying must not churn the file, or every scaffold run shows as a diff.
before="$(md5sum < "$t18/CLAUDE.md")"
"$apt" ml "$t18" >/dev/null
[ "$before" = "$(md5sum < "$t18/CLAUDE.md")" ] || fail "[18] re-applying ml rewrote the file"

# The other direction, and the reason BASE_STYLES excludes slurm: slurm is an
# additive block. Adding Slurm rules is not a request to delete the base rules,
# and switching the base style is not a request to delete the Slurm rules.
t18b="$TMP/style-additive"; mkdir -p "$t18b"
"$apt" general "$t18b" >/dev/null
"$apt" slurm "$t18b" >/dev/null
got="$(blocks_in "$t18b/CLAUDE.md")"
[ "$got" = "general slurm " ] || fail "[18] slurm alone disturbed the base style: $got"
"$apt" ml "$t18b" >/dev/null
got="$(blocks_in "$t18b/CLAUDE.md")"
[ "$got" = "ml slurm " ] || fail "[18] switching base style dropped the slurm block: $got"

echo "[19] a registration pointing at the wrong program is drift, not 'already registered'"
# Reproduced on this machine: serena sat in `claude mcp list` under the right
# name for months while pointing at a different build of serena than the one
# setup.sh installs. add_mcp compared env and never the command, so every sync
# said "OK — already registered" and the server never started. The two builds do
# not share a config schema (HEAD writes `language_servers:` into
# .serena/project.yml, the pinned release reads `languages:` and raises
# KeyError), so "some serena is registered" was not the same as "serena works".
# shellcheck disable=SC1091
. "$ROOT/lib/sync/plugins-mcp.sh"

t19="$TMP/mcp-registry"; mkdir -p "$t19"
cat > "$t19/.claude.json" <<'JSON'
{
  "mcpServers": {
    "serena": {
      "type": "stdio",
      "command": "uvx",
      "args": ["--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server"],
      "env": {"PATH": "/nowhere", "KEEP_ME": "yes"}
    },
    "codex-mcp": {
      "command": "codex-mcp",
      "args": [],
      "env": {"PATH": "/nowhere", "MCP_CODEX_DEFAULT_MODEL": "gpt-5.5"}
    },
    "supermemory": {"command": "npx", "args": ["-y", "supermemory-mcp"]}
  }
}
JSON
CANON="claude mcp add -s user serena -e PATH=/bin -- serena start-mcp-server --context claude-code --open-web-dashboard false"

# The whole point: same name, different program.
HOME="$t19" mcp_cmdline_drift serena "$CANON" \
  || fail "[19] a serena registered as uvx-from-git read as up to date against the release command"

# ...and the reason must name both sides, or the log cannot be acted on.
got="$(HOME="$t19" bash -c '. "'"$ROOT"'/lib/sync/plugins-mcp.sh"; mcp_cmdline_drift serena "'"$CANON"'"; printf "%s|%s" "$MCP_DRIFT_HAVE" "$MCP_DRIFT_WANT"')"
case "$got" in
  "uvx --from git+https://github.com/oraios/serena serena start-mcp-server|serena start-mcp-server --context claude-code --open-web-dashboard false") ;;
  *) fail "[19] drift reported the wrong pair: $got" ;;
esac

# No false positives, or every sync tears down and re-registers a healthy entry.
HOME="$t19" mcp_cmdline_drift codex-mcp "claude mcp add -s user codex-mcp -e PATH=/bin -- codex-mcp" \
  && fail "[19] an entry that already matches was reported as drifted"

# An http/sse registration has no `--` and therefore no command line to compare.
# The fixture is the case that makes this load-bearing: supermemory carries a
# leftover stdio command from when it was registered that way, so without the
# `--` guard the whole `claude mcp add --transport http …` string gets compared
# against `npx -y supermemory-mcp`, drift is declared on every sync, and the
# entry is torn down and rebuilt forever. Comparing transports is not something
# this function claims to do.
HOME="$t19" mcp_cmdline_drift supermemory "claude mcp add -s user --transport http supermemory https://mcp.supermemory.ai/mcp" \
  && fail "[19] an http registration was compared against a stdio command line"

# A name we do not own at user scope (project-scope .mcp.json entries) is not ours to move.
HOME="$t19" mcp_cmdline_drift context7 "claude mcp add -s user context7 -- context7-server" \
  && fail "[19] claimed drift on a name absent from the user registry"

# Re-registration must carry the user's own env across, minus keys the canonical
# command already sets — otherwise repairing a command silently drops config, or
# reinstates a stale value by appending it after ours.
got="$(HOME="$t19" mcp_user_field serena env | tr '\n' ' ')"
[ "$got" = "KEEP_ME=yes " ] || fail "[19] env view returned '$got' (want KEEP_ME only; PATH has its own check)"
got="$(HOME="$t19" mcp_user_field codex-mcp env | tr '\n' ' ')"
[ "$got" = "MCP_CODEX_DEFAULT_MODEL=gpt-5.5 " ] || fail "[19] env view lost a preserved key: $got"

# The baked PATH has to be read from the registry too. add_mcp took it from
# `claude mcp get`, which in a directory whose .mcp.json names the same server
# reports "Scope: Project config" and prints no env lines at all — so the PATH
# comparison saw <unset> forever and re-registered serena on every single sync.
# Measured on this machine before the fix.
got="$(HOME="$t19" mcp_user_field serena path)"
[ "$got" = "/nowhere" ] || fail "[19] PATH view returned '$got' instead of the registered value"
got="$(HOME="$t19" mcp_user_field context7 path)"
[ -z "$got" ] || fail "[19] PATH view invented a value for a name we do not own: $got"
# Registered, but with no baked PATH. Reporting anything here would mean the
# comparison is against a value nobody wrote, and the entry gets rebuilt forever.
got="$(HOME="$t19" mcp_user_field supermemory path)"
[ -z "$got" ] || fail "[19] PATH view reported '$got' for an entry that bakes no PATH"

# The bug this fixes was two provisioning paths for one tool. setup.sh installs
# the pinned release and oma's .mcp.json runs `serena` off PATH, so sync must
# register that same binary — and must guard on it, so a missing install SKIPs
# instead of registering an entry that can never start.
serena_line="$(grep -A2 'add_mcp "serena"' "$ROOT/lib/sync/plugins-mcp.sh" | tr '\n' ' ')"
case "$serena_line" in
  *"uvx"*|*"git+"*) fail "[19] sync registers serena from git HEAD again — that is the second build" ;;
esac
# Quoted "serena" appears exactly twice when the guard is present — once as the
# name, once as the binary argument. The command string spells the binary
# unquoted, so this counts the guard and not the command.
guards="$(printf '%s' "$serena_line" | grep -o '"serena"' | wc -l)"
[ "$guards" -eq 2 ] || fail "[19] serena registered with no binary guard (found $guards quoted names)"

echo "[20] the codex runtime dep check runs where tomllib does not exist"
# This machine is python 3.10, so the check imported tomllib, printed [SKIP] and
# emitted __WARN__0 — the same zero warnings a clean pass emits. The entire
# runtime-dependency class had therefore never run here while doctor reported
# health. The fallback parser only helps if it reads this file correctly, and
# the file is full of traps: [mcp_servers.context-mode.tools.ctx_search] carries
# its own `command`, and a `.tools.` table must never be read as `.env.`.
t20="$TMP/codex-toml"; mkdir -p "$t20"
cat > "$t20/config.toml" <<'TOML'
# leading comment
model = "gpt-5.5"

[mcp_servers.serena]
command = "/home/byun/.local/bin/serena"
args = ["start-mcp-server"]

[mcp_servers.serena.env]
PATH = "/opt/bin:/usr/bin"

[mcp_servers.context-mode]
command = "context-mode"

[mcp_servers.context-mode.env]
PATH = "/ctx/bin"

[mcp_servers.context-mode.tools.ctx_search]
command = "SHOULD-NOT-BE-READ"
PATH = "/should/not/be/read"

[other_section]
command = "also-not-a-server"
TOML

got="$(python3 - "$ROOT/lib/doctor/agent-mcp.sh" "$t20/config.toml" <<'PY'
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
body = re.search(r"\ndef load_min\(path\):.*?\n    return servers\n", src, re.S)
if not body:
    print("PARSER-NOT-FOUND"); raise SystemExit(0)
ns = {"re": re}
exec(body.group(0), ns)
print(json.dumps(ns["load_min"](sys.argv[2]), sort_keys=True))
PY
)"
want='{"context-mode": {"command": "context-mode", "env": {"PATH": "/ctx/bin"}}, "serena": {"command": "/home/byun/.local/bin/serena", "env": {"PATH": "/opt/bin:/usr/bin"}}}'
[ "$got" = "$want" ] || fail "[20] minimal TOML parser returned:
  $got
want:
  $want"

# A config whose servers the parser cannot read must say so. Reporting nothing
# is what made the missing tomllib invisible in the first place.
cat > "$t20/quoted.toml" <<'TOML'
["mcp_servers"."serena"]
command = "serena"
TOML
got="$(python3 - "$ROOT/lib/doctor/agent-mcp.sh" "$t20/quoted.toml" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
body = re.search(r"\ndef load_min\(path\):.*?\n    return servers\n", src, re.S)
ns = {"re": re}
exec(body.group(0), ns)
raw = open(sys.argv[2], encoding="utf-8").read()
served = ns["load_min"](sys.argv[2])
present = re.search(r'^\s*\[\s*"?mcp_servers"?\s*\.', raw, re.M) is not None
print("unread" if (not served and present) else "silent")
PY
)"
[ "$got" = "unread" ] || fail "[20] a config the parser cannot read was reported as having no servers"

echo "[21] doctor says WHY an MCP server is missing, and only when it can tell"
# `[MISS] serena` on its own points at the wrong repair — the entry was present
# and named correctly, it just pointed at a program that could not start. The
# reason logic shipped without a test, so nothing held it to the distinction it
# exists to make: a command that cannot resolve is diagnosable from the registry
# alone, while an http server being down is an auth or network answer doctor
# must not guess at.
t21="$TMP/mcp-reason"; mkdir -p "$t21/bin"
printf '#!/bin/sh\n' > "$t21/bin/found-mcp"; chmod +x "$t21/bin/found-mcp"
printf '#!/bin/sh\n' > "$t21/bin/abs-mcp";   chmod +x "$t21/bin/abs-mcp"
printf 'not executable\n' > "$t21/bin/no-exec-mcp"

# Extract the reason logic from the doctor source rather than restating it, so a
# change there is a change here.
awk '/<< .PYEOF.$/{n++; if (n==1) {grab=1; next}} grab && /^PYEOF$/{exit} grab' \
  "$ROOT/lib/doctor/claude.sh" > "$t21/reason.py"
[ -s "$t21/reason.py" ] || fail "[21] could not extract the reason logic from lib/doctor/claude.sh"

cat > "$t21/registry.json" <<JSON
{
  "mcpServers": {
    "bare-missing":   {"command": "definitely-not-installed-xyz"},
    "baked-missing":  {"command": "definitely-not-installed-xyz", "env": {"PATH": "$t21/bin"}},
    "baked-found":    {"command": "found-mcp", "env": {"PATH": "$t21/bin"}},
    "abs-missing":    {"command": "$t21/bin/does-not-exist"},
    "abs-found":      {"command": "$t21/bin/abs-mcp"},
    "abs-not-exec":   {"command": "$t21/bin/no-exec-mcp"},
    "remote-http":    {"type": "http", "url": "https://example.invalid/mcp"},
    "remote-sse":     {"type": "sse", "command": "irrelevant", "url": "https://example.invalid/sse"}
  }
}
JSON

# Absolute interpreter, emptied PATH: the point is what the CHECKED entries can
# resolve, and leaving the test runner's PATH in place would let `bare-missing`
# accidentally find something.
py3="$(command -v python3)"
out="$(PATH="/nonexistent" "$py3" "$t21/reason.py" "$t21/registry.json" 2>&1)"
named="$(printf '%s\n' "$out" | cut -f1 | sort | tr '\n' ' ')"
[ "$named" = "abs-missing abs-not-exec baked-missing bare-missing " ] \
  || fail "[21] reasons were reported for: $named"

# The two PATH kinds must not be described interchangeably — they point at
# different repairs (install it, vs. re-run sync so the entry bakes a PATH).
printf '%s\n' "$out" | grep -q '^bare-missing	.*inherited PATH' \
  || fail "[21] a command with no baked PATH was not blamed on the inherited PATH"
printf '%s\n' "$out" | grep -q '^baked-missing	.*baked PATH' \
  || fail "[21] a command with a baked PATH was not blamed on that PATH"

echo "[22] the pre-push gate blocks a bad push and never eats someone else's hook"
# Opt-in by design, so sync does not install it — which means nothing else would
# notice if it stopped working. The properties worth holding are the ones that
# make it either useless or destructive: it must actually fail the push, it must
# fail rather than wave the push through when its own gate script is gone, and it
# must not silently replace a pre-push hook someone else wrote.
ih="$ROOT/scripts/install-hooks.sh"
t22="$TMP/hookrepo"; mkdir -p "$t22/scripts"
git -C "$t22" init -q .
git -C "$t22" config user.email t@t; git -C "$t22" config user.name t
gate="$t22/scripts/check.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$gate"; chmod +x "$gate"
hook="$t22/.git/hooks/pre-push"

( cd "$t22" && bash "$ih" >/dev/null ) || fail "[22] install failed"
[ -x "$hook" ] || fail "[22] no executable pre-push hook was installed"

# Idempotent: running it twice must not stack or duplicate anything.
before="$(md5sum < "$hook")"
( cd "$t22" && bash "$ih" >/dev/null ) || fail "[22] reinstall failed"
[ "$before" = "$(md5sum < "$hook")" ] || fail "[22] reinstalling rewrote the hook differently"

# The whole point: a failing gate stops the push.
printf '#!/usr/bin/env bash\nexit 3\n' > "$gate"
( cd "$t22" && bash "$hook" </dev/null >/dev/null 2>&1 ) && fail "[22] the hook passed while check.sh failed"
printf '#!/usr/bin/env bash\nexit 0\n' > "$gate"
( cd "$t22" && bash "$hook" </dev/null >/dev/null 2>&1 ) || fail "[22] the hook failed on a clean gate"

# Fail closed. A gate whose script vanished must not report the same success a
# clean run reports — that is the shape of every false-green in this repo.
mv "$gate" "$gate.away"
( cd "$t22" && bash "$hook" </dev/null >/dev/null 2>&1 ) && fail "[22] a missing check.sh let the push through"
mv "$gate.away" "$gate"

# Someone else's hook is not ours to delete.
( cd "$t22" && bash "$ih" --uninstall >/dev/null ) || fail "[22] uninstall failed"
[ -e "$hook" ] && fail "[22] uninstall left our hook in place"
printf '#!/bin/sh\necho theirs\n' > "$hook"; chmod +x "$hook"
( cd "$t22" && bash "$ih" >/dev/null 2>&1 ) && fail "[22] a foreign pre-push hook was replaced without --force"
grep -q theirs "$hook" || fail "[22] a foreign hook was modified by a refused install"
( cd "$t22" && bash "$ih" --uninstall >/dev/null 2>&1 ) && fail "[22] uninstall removed a hook it did not write"
grep -q theirs "$hook" || fail "[22] uninstall damaged a foreign hook"
( cd "$t22" && bash "$ih" --force >/dev/null ) || fail "[22] --force install failed"
grep -q theirs "$hook.pre-oma" || fail "[22] --force did not preserve the foreign hook"

echo "[23] a managed MCP entry pointing at the wrong build is repointed, in every runtime"
# The Claude and Codex registrations were repointed off upstream HEAD, and serena
# broke again on the next restart anyway: agy's shared config still named
# `uvx --from git+…`, because this step skipped on the NAME being present and
# never compared the spec. agy starts that entry in whatever directory
# antigravity runs from, and HEAD writes .serena/project.yml as
# `language_servers:`, which the pinned release cannot load. Proven by control:
# with the file at `languages:`, running the release left it alone and running
# the HEAD command flipped it.
t23="$TMP/mcp-runtimes"; mkdir -p "$t23/codex" "$t23/gemini/config"
# No `$` anchor: this heredoc line carries a trailing pipe (`| sed ...`), unlike
# the ones in lib/doctor. Anchoring silently extracted nothing.
awk '/<< .PYEOF./{n++; if (n==1) {grab=1; next}} grab && /^PYEOF$/{exit} grab' \
  "$ROOT/lib/sync/frameworks.sh" > "$t23/register.py"
[ -s "$t23/register.py" ] || fail "[23] could not extract the registration step from lib/sync/frameworks.sh"

cat > "$t23/codex/config.toml" <<'TOML'
[mcp_servers.serena]
command = "/home/byun/.local/bin/uvx"
args = ["--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server"]

[mcp_servers.serena.env]
PATH = "/opt/bin"
TOML
cat > "$t23/gemini/config/mcp_config.json" <<'JSON'
{
  "mcpServers": {
    "serena": {"command": "uvx", "args": ["--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server"]},
    "someone-elses": {"command": "their-server", "args": ["--keep-me"]}
  }
}
JSON

python3 "$t23/register.py" "$t23/codex" "$t23/gemini" >/dev/null 2>&1 \
  || fail "[23] the registration step failed on the fixture"

got="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["mcpServers"]
print(json.dumps(d["serena"], sort_keys=True))
' "$t23/gemini/config/mcp_config.json")"
[ "$got" = '{"args": ["start-mcp-server"], "command": "serena"}' ] \
  || fail "[23] agy config still names the wrong build: $got"

# Someone else's entry is not ours to rewrite — only the names we manage are.
got="$(python3 -c '
import json, sys
print(json.dumps(json.load(open(sys.argv[1]))["mcpServers"].get("someone-elses"), sort_keys=True))
' "$t23/gemini/config/mcp_config.json")"
[ "$got" = '{"args": ["--keep-me"], "command": "their-server"}' ] \
  || fail "[23] a third-party entry was rewritten: $got"

# Codex is the same defect in TOML form: the section existed, so it was left.
grep -q 'command = "serena"' "$t23/codex/config.toml" \
  || fail "[23] codex config.toml still points at uvx/git HEAD"
grep -q 'git+' "$t23/codex/config.toml" \
  && fail "[23] codex config.toml still carries a git+ argument"

# Idempotent, and it says which of the two happened. This step collected its
# changes into a list it never printed, so a repoint left no trace in sync output.
out="$(python3 "$t23/register.py" "$t23/codex" "$t23/gemini" 2>&1)"
printf '%s\n' "$out" | grep -q 'Antigravity: managed MCP entries already canonical' \
  || fail "[23] a second run did not report the config as already canonical: $out"

echo "[24] a project config written by a different serena is named, not left to the next restart"
# serena resolved, the binary existed, and the server still died before the
# handshake: .serena/project.yml had been written by upstream HEAD, which spells
# the field `language_servers:` where the pinned release requires `languages:`.
# doctor printed `[MISS] serena` with no reason attached, because the reason
# logic asks whether the COMMAND resolves — and it did. Repointing the three
# registrations removed the cause; missing one of them again is silent until
# someone restarts, which is how this was found the first time.
t24="$TMP/serena-schema"; mkdir -p "$t24/bin" "$t24/dead" "$t24/other"
# Extracted, not restated: a copy of the logic keeps passing after the original
# changes. The block is self-contained between its first assignment and the `fi`
# that closes it — the nested ones are indented deeper.
awk '/^  _sr_bin="/{grab=1} grab; grab && /^  fi$/{exit}' \
  "$ROOT/lib/doctor/agent-mcp.sh" > "$t24/check.sh"
grep -q 'serena-schema.py' "$t24/check.sh" \
  || fail "[24] could not extract the serena schema check from lib/doctor/agent-mcp.sh"

# --- layer 1: the verdict logic, driven through a stand-in serena module ------
# lib/doctor/serena-schema.py asks the INSTALLED build two things: which fields
# have no default, and what the file loads to. Both are faked here so the test
# does not need serena installed, and so a build that demands a DIFFERENT field
# can be shown to change the verdict on the same file — that is the property
# that keeps the required list from drifting back into a hardcoded one.
# The fake returns the dict straight from JSON: the python under test consumes a
# loader's output, not YAML text, so JSON exercises exactly the same path.
mk_fake_serena() { # mk_fake_serena <dir> <required-fields...>
  local d="$1"; shift
  mkdir -p "$d/serena/config"
  : > "$d/serena/__init__.py"
  : > "$d/serena/config/__init__.py"
  {
    printf 'import json\n'
    printf 'class ProjectConfig:\n'
    printf '    FIELDS_WITHOUT_DEFAULTS = {%s}\n' "$(for f in "$@"; do printf '"%s",' "$f"; done)"
    printf '    @staticmethod\n'
    printf '    def _load_yaml_dict(p):\n'
    printf '        return json.load(open(p)), True\n'
  } > "$d/serena/config/serena_config.py"
}
mk_fake_serena "$t24/fake" project_name languages
mk_fake_serena "$t24/fake_other" some_other_field

mkcfg24() { mkdir -p "$1/.serena"; printf '%s' "$2" > "$1/.serena/project.yml"; }
py24() { PYTHONPATH="$1" python3 "$ROOT/lib/doctor/serena-schema.py" "${@:2}" 2>&1; }

L_OK="$t24/L/ok";     mkcfg24 "$L_OK"    '{"project_name":"x","languages":["python"]}'
L_HEAD="$t24/L/head"; mkcfg24 "$L_HEAD"  '{"project_name":"x","language_backend":null,"language_servers":["python"]}'
L_EMPTY="$t24/L/em";  mkcfg24 "$L_EMPTY" '{"project_name":"x","languages":[]}'
L_JUNK="$t24/L/junk"; mkcfg24 "$L_JUNK"  'not json at all'

out="$(py24 "$t24/fake" "$L_OK/.serena/project.yml")"
printf '%s\n' "$out" | grep -q '^\[OK\].*languages=python' || fail "[24] a loadable config was not accepted: $out"

# The regression itself, in the spelling HEAD actually writes. A grep for
# `^languages:` cannot tell this from "present but empty"; the loader can.
out="$(py24 "$t24/fake" "$L_HEAD/.serena/project.yml")"
printf '%s\n' "$out" | grep -q '^\[MISS\].*languages' \
  || fail "[24] a config written by the wrong build passed: $out"
printf '%s\n' "$out" | grep -q 'it carries language_servers instead' \
  || fail "[24] the culprit key was not named: $out"
# language_backend also matches on name and is legitimately empty. Naming it
# sends the reader to rename a key that is not the problem.
printf '%s\n' "$out" | grep -q 'carries.*language_backend' \
  && fail "[24] an unrelated language-ish key was blamed: $out"

# Present-but-empty is a third state, and it is not an error: a repo with no
# source files is legitimately empty. It is still said out loud, because from
# the outside an empty list looks exactly like a working setup.
out="$(py24 "$t24/fake" "$L_EMPTY/.serena/project.yml")"
printf '%s\n' "$out" | grep -q '^\[NOTE\].*empty' || fail "[24] an empty languages list was silent: $out"
printf '%s\n' "$out" | grep -q '^\[MISS\]' && fail "[24] an empty list was reported as missing: $out"

out="$(py24 "$t24/fake" "$L_JUNK/.serena/project.yml")"
printf '%s\n' "$out" | grep -q '^\[WARN\].*could not be parsed' \
  || fail "[24] an unparsable config did not warn: $out"

# The required list belongs to the installed build, not to this repo.
out="$(py24 "$t24/fake_other" "$L_OK/.serena/project.yml")"
printf '%s\n' "$out" | grep -q '^\[MISS\].*some_other_field' \
  || fail "[24] the required keys are hardcoded — a different build got the same answer"

# The same worktree is reachable by two paths on this machine; reporting it
# twice would read as two problems.
out="$(py24 "$t24/fake" "$L_HEAD/.serena/project.yml" "$L_HEAD/.serena/project.yml")"
[ "$(printf '%s\n' "$out" | grep -c '^\[MISS\]')" = 1 ] \
  || fail "[24] the same config was reported twice: $out"

# --- layer 1b: --fix repairs the file instead of describing the repair --------
# Reporting-only was the first design. It left one YAML to hand-edit per repo
# per machine, which is what the operator objected to and what the harness's own
# "config logic must be idempotent" rule forbids. The properties asserted here
# are the ones that make a config rewrite safe to ship, and each was a real
# failure mode raised in review rather than an imagined one.
#
# This fake parses the file as text, unlike the JSON one above: --fix edits
# lines, so a JSON fixture would never exercise the code under test.
mkdir -p "$t24/fake_yml/serena/config"
: > "$t24/fake_yml/serena/__init__.py"; : > "$t24/fake_yml/serena/config/__init__.py"
cat > "$t24/fake_yml/serena/config/serena_config.py" <<'PYEOF'
class ProjectConfig:
    FIELDS_WITHOUT_DEFAULTS = {"project_name", "languages"}
    @staticmethod
    def _load_yaml_dict(p):
        d, cur = {}, None
        for raw in open(p, encoding="utf-8"):
            if raw.lstrip().startswith("#") or not raw.strip():
                continue
            if raw.startswith(" ") or raw.startswith("\t"):
                if raw.strip().startswith("- ") and cur:
                    d[cur].append(raw.strip()[2:])
                continue
            k, _, v = raw.partition(":")
            v = v.split("#", 1)[0].strip()
            d[k], cur = (v if v else []), k
        return d, True
PYEOF

BROKEN24='project_name: fixture
# a comment naming language_servers: must never be rewritten
language_servers:
  - python
  - bash
  indented_language_servers: keep-me
language_backend:
'
mkcfg24 "$t24/fixme" "$BROKEN24"
cp "$t24/fixme/.serena/project.yml" "$t24/expected-before.yml"

# Default is the dry run. A health check that edits files when not asked is a
# health check nobody can run safely.
out="$(py24 "$t24/fake_yml" "$t24/fixme/.serena/project.yml")"
cmp -s "$t24/expected-before.yml" "$t24/fixme/.serena/project.yml" \
  || fail "[24] running without --fix modified the config"

# The same worktree under two paths shares one inode here, exactly as the real
# ones do. An atomic temp-write-then-rename would split that link and leave the
# two paths silently diverged, so the write has to be in place.
ln "$t24/fixme/.serena/project.yml" "$t24/hardlink.yml"
ino_before="$(stat -c %i "$t24/fixme/.serena/project.yml")"

out="$(py24 "$t24/fake_yml" --fix "$t24/fixme/.serena/project.yml")"
printf '%s\n' "$out" | grep -q '\[FIXED\].*language_servers -> languages' \
  || fail "[24] --fix did not repair a config the loader could not read: $out"
[ "$(stat -c %i "$t24/fixme/.serena/project.yml")" = "$ino_before" ] \
  || fail "[24] --fix replaced the inode — a hardlinked worktree config would have split"
grep -q '^languages:' "$t24/hardlink.yml" \
  || fail "[24] the hardlinked path did not see the repair"

# Only the key changes. These files carry ~10KB of comments; a YAML round-trip
# would delete all of it and the test would still pass on "it loads".
grep -q '# a comment naming language_servers: must never be rewritten' "$t24/fixme/.serena/project.yml" \
  || fail "[24] --fix rewrote a comment that merely mentions the key"
grep -q '  indented_language_servers: keep-me' "$t24/fixme/.serena/project.yml" \
  || fail "[24] --fix touched an indented key instead of the top-level one"
grep -q '^language_backend:' "$t24/fixme/.serena/project.yml" \
  || fail "[24] --fix renamed the empty decoy key as well"
# Compared against the copy taken before the fix, not against a re-rendering of
# the fixture string: the first version of this line rebuilt the expected text
# with printf and counted one newline too many, so it failed on a correct fix.
[ "$(wc -l < "$t24/expected-before.yml")" = "$(wc -l < "$t24/fixme/.serena/project.yml")" ] \
  || fail "[24] --fix changed the line count — this is a key rename, not a reformat"
# And only one line differs at all.
[ "$(diff "$t24/expected-before.yml" "$t24/fixme/.serena/project.yml" | grep -c '^[<>]')" = 2 ] \
  || fail "[24] --fix changed more than the single key line"

# Idempotent, and it leaves nothing behind. A .bak accumulating next to a config
# is how a later run restores a stale intermediate state.
out="$(py24 "$t24/fake_yml" --fix "$t24/fixme/.serena/project.yml")"
printf '%s\n' "$out" | grep -q '^\[OK\]' \
  || fail "[24] a second --fix did not report the config as already loading: $out"
[ -e "$t24/fixme/.serena/project.yml.oma-bak" ] \
  && fail "[24] --fix left a backup behind"

# Nothing to rename is not the same as a repair. Saying so keeps "could not fix"
# out of the same output shape as "fixed".
mkcfg24 "$t24/nocand" 'project_name: bare
'
out="$(py24 "$t24/fake_yml" --fix "$t24/nocand/.serena/project.yml")"
printf '%s\n' "$out" | grep -q 'SKIP FIX' \
  || fail "[24] a config with no rename candidate was not reported as unfixable: $out"

# Two plausible candidates is a guess, and guessing which key holds the truth
# is how a repair corrupts a config. Without this fixture the guard is
# untested: removing it survived every other assertion here.
mkcfg24 "$t24/twocand" 'project_name: ambiguous
language_servers:
  - python
extra_languages_list:
  - bash
'
out="$(py24 "$t24/fake_yml" --fix "$t24/twocand/.serena/project.yml")"
printf '%s\n' "$out" | grep -q 'SKIP FIX' \
  || fail "[24] --fix picked between two rename candidates instead of refusing: $out"
grep -q '^language_servers:' "$t24/twocand/.serena/project.yml" \
  || fail "[24] --fix edited a config it said it would not repair"

# A rename that leaves the loader still unhappy must be undone. Fake build that
# refuses an empty language list, so the rename lands and verification still
# fails — the only shape that exercises the restore path.
mkdir -p "$t24/fake_strict/serena/config"
: > "$t24/fake_strict/serena/__init__.py"; : > "$t24/fake_strict/serena/config/__init__.py"
# The candidate must hold a NON-EMPTY list or it is never a rename candidate at
# all — the first version of this fixture used an empty one, so repair() was
# never called and the assertions below passed without exercising anything.
sed 's/return d, True/return (({} if "poison" in (d.get("languages") or []) else d), True)/' \
  "$t24/fake_yml/serena/config/serena_config.py" > "$t24/fake_strict/serena/config/serena_config.py"
mkcfg24 "$t24/strict" 'project_name: strict
language_servers:
  - poison
'
cp "$t24/strict/.serena/project.yml" "$t24/strict-before.yml"
out="$(py24 "$t24/fake_strict" --fix "$t24/strict/.serena/project.yml")"
printf '%s\n' "$out" | grep -q '\[FIX FAILED\]' \
  || fail "[24] a rename the loader still rejects was not reported as failed: $out"
printf '%s\n' "$out" | grep -q '\[FIXED\]' \
  && fail "[24] --fix claimed success on a config the loader still rejects: $out"
cmp -s "$t24/strict-before.yml" "$t24/strict/.serena/project.yml" \
  || fail "[24] a failed repair was not rolled back"
[ -e "$t24/strict/.serena/project.yml.oma-bak" ] \
  && fail "[24] a failed repair left its backup behind"

# --registered reaches the configs this checkout cannot see. Checking only the
# current repo is why a broken config in a research repo stayed invisible until
# doctor happened to run from inside it, and why fixing a machine meant one
# `cd` per repo. serena's registry is the list it will actually open.
reghome24="$t24/reghome"; mkdir -p "$reghome24/.serena"
mkcfg24 "$t24/regproj" 'project_name: registered
languages:
  - python
'
printf 'projects:\n- %s\n' "$t24/regproj" > "$reghome24/.serena/serena_config.yml"
out="$(HOME="$reghome24" py24 "$t24/fake_yml" --registered)"
printf '%s\n' "$out" | grep -q "$t24/regproj" \
  || fail "[24] --registered did not reach a project outside the given paths: $out"
# And it is opt-in: without the flag the same call sees nothing.
out="$(HOME="$reghome24" py24 "$t24/fake_yml")"
printf '%s\n' "$out" | grep -q "$t24/regproj" \
  && fail "[24] the registry was read without --registered"

# --- layer 2: the bash wiring ------------------------------------------------
# A stand-in serena whose shebang names a stand-in interpreter. The wiring reads
# the interpreter out of the binary and hands it the checker plus the configs.
mk_serena() { # mk_serena <dir> <verdict-line|"">
  local d="$1"; shift
  if [ -n "$1" ]; then
    printf '#!/bin/sh\necho "%s"\n' "$1" > "$d/py"
  else
    printf '#!/bin/sh\nexit 1\n' > "$d/py"      # cannot answer
  fi
  printf '#!%s/py\n' "$d" > "$d/serena"
  chmod +x "$d/py" "$d/serena"
}
mk_serena "$t24/bin" '[OK] fixture loads; languages=python'
mk_serena "$t24/other" '[MISS] fixture lacks required key(s): some_other_field'
printf '#!%s/absent\n' "$t24" > "$t24/dead/serena"; chmod +x "$t24/dead/serena"

# PATH is set explicitly rather than prefixed: the real serena lives in
# ~/.local/bin, so an inherited PATH would let the genuine build answer for the
# fixture. Absolute bash for the same reason a bare `python3` once exited 127.
BASH24="$(command -v bash)"
P_OK="$t24/bin:/usr/bin:/bin"; P_DEAD="$t24/dead:/usr/bin:/bin"
P_OTHER="$t24/other:/usr/bin:/bin"; P_NONE="/usr/bin:/bin"
PATH="$P_NONE" command -v serena >/dev/null 2>&1 \
  && fail "[24] serena is on the stripped PATH — the not-installed case cannot be tested here"

# cwd is pinned to a non-git directory as well as SCRIPT_DIR, because the check
# now also looks at the repo the session is running in. Without that, every case
# below picks up this harness's own real .serena/project.yml through
# `git rev-parse --show-toplevel` and the fixtures decide nothing.
nogit24="$t24/nogit"; mkdir -p "$nogit24"
run24() { # run24 <project-dir> <path> [cwd]
  ( cd "${3:-$nogit24}" && SCRIPT_DIR="$1" PATH="$2" "$BASH24" -c '
      WARNINGS=0
      maybe_timeout() { shift; "$@"; }
      . "$1"
      echo "WARNINGS=$WARNINGS"
    ' _ "$t24/check.sh" ) 2>&1
}

ok24="$t24/ok"; mkdir -p "$ok24/.serena"
printf 'project_name: x\nlanguages:\n  - python\n' > "$ok24/.serena/project.yml"
out="$(run24 "$ok24" "$P_OK")"
printf '%s\n' "$out" | grep -q '\[OK\]' || fail "[24] a loadable config was not accepted: $out"
printf '%s\n' "$out" | grep -qx 'WARNINGS=0' || fail "[24] a loadable config raised a warning: $out"

# The config that is actually failing belongs to the repo the SESSION is in, not
# to this checkout. Checking only SCRIPT_DIR is how 13 broken configs stayed
# invisible while doctor reported a clean serena every time.
cwd24="$t24/cwdrepo"; mkdir -p "$cwd24/.serena"
printf 'project_name: y\nlanguages:\n  - python\n' > "$cwd24/.serena/project.yml"
( cd "$cwd24" && git init -q . ) >/dev/null 2>&1
bare_for_cwd="$t24/bare-b"; mkdir -p "$bare_for_cwd"
out="$(run24 "$bare_for_cwd" "$P_OK" "$cwd24")"
printf '%s\n' "$out" | grep -q '\[OK\] fixture' \
  || fail "[24] the config in the session's own repo was never checked: $out"

# A [MISS] from the checker has to reach doctor's warning count, or the section
# prints the problem and still exits clean.
out="$(run24 "$ok24" "$P_OTHER")"
printf '%s\n' "$out" | grep -q '\[MISS\].*some_other_field' \
  || fail "[24] the checker's verdict was not relayed: $out"
printf '%s\n' "$out" | grep -qx 'WARNINGS=1' \
  || fail "[24] a MISS verdict did not count as a warning: $out"

# Absent config and absent serena are both "nothing to check", and neither is a
# problem worth a warning.
bare24="$t24/bare"; mkdir -p "$bare24"
# "Nothing to check" now means no activated checkout AND no serena registry.
# Skipping on the checkout alone is what hid the configs that mattered: the
# broken ones lived in research repos, so doctor only ever saw them if it
# happened to be invoked from inside one, and repairing a machine meant
# visiting each repo by hand. HOME is redirected so the developer's real
# registry cannot decide this assertion either way.
home24="$t24/nohome"; mkdir -p "$home24"
out="$(HOME="$home24" run24 "$bare24" "$P_OK")"
printf '%s\n' "$out" | grep -q '\[SKIP\]' || fail "[24] a non-activated checkout with no registry was not skipped: $out"
printf '%s\n' "$out" | grep -qx 'WARNINGS=0' || fail "[24] a non-activated checkout warned: $out"

# With a registry present the check runs even from a directory that is not
# itself activated — that is the whole point of reaching the other repos.
reg24="$t24/withhome"; mkdir -p "$reg24/.serena"
printf 'projects:\n- %s\n' "$bare24" > "$reg24/.serena/serena_config.yml"
mkdir -p "$bare24/.serena"; printf 'project_name: registered-only\nlanguages:\n- python\n' > "$bare24/.serena/project.yml"
out="$(HOME="$reg24" run24 "$bare24" "$P_OK")"
printf '%s\n' "$out" | grep -q '\[SKIP\]' \
  && fail "[24] a registry was present and the check still skipped: $out"
# Whether the registry is actually READ is asserted at layer 1 instead: the
# stand-in interpreter here echoes a fixed verdict and cannot show which paths
# it was handed.
out="$(run24 "$ok24" "$P_NONE")"
printf '%s\n' "$out" | grep -q '\[SKIP\]' || fail "[24] an uninstalled serena was not skipped: $out"
printf '%s\n' "$out" | grep -qx 'WARNINGS=0' || fail "[24] an uninstalled serena warned: $out"

# But an interpreter that cannot answer is NOT a pass. This is the shape the
# codex runtime dep check had while it sat unrun for a whole python version:
# unable to check, reporting the zero warnings a clean run reports.
out="$(run24 "$ok24" "$P_DEAD")"
printf '%s\n' "$out" | grep -q '\[WARN\].*unverified' \
  || fail "[24] an unaskable serena reported like a clean pass: $out"
printf '%s\n' "$out" | grep -qx 'WARNINGS=1' \
  || fail "[24] an unverified schema did not count as a warning: $out"

echo "[25] the rules the runtime reads are held to the SSOT they came from"
# A project carries its rules twice: .agents/rules is the SSOT and the path
# CLAUDE.md tells the model to read, .claude/rules is what the runtime actually
# loads into context. Both are written by the oma package, neither by sync, and
# nothing compared them — they agreed by luck. The bodies could drift and the
# model would follow the copy the documentation does not name.
t25="$TMP/rule-mirror"; mkdir -p "$t25"
# Anchored on the section header, not on the heredoc line: a second section in
# the same file opens its heredoc the same way, and when one was added above
# this one the bare anchor silently extracted the wrong block.
awk '/echo "\[ Rule mirror/{sec=1} sec && /^import /{grab=1} grab && /^PYEOF$/{exit} grab' \
  "$ROOT/lib/doctor/claude.sh" > "$t25/check.py"
grep -q 'paths' "$t25/check.py" \
  || fail "[25] could not extract the rule-mirror check from lib/doctor/claude.sh"
py25="$(command -v python3)"   # absolute: a bare python3 once exited 127 here

mk25() { # mk25 <root> <tree> <name> <scope-key> <scope-value> <body-line>
  mkdir -p "$1/$2"
  {
    printf -- '---\ndescription: x\n'
    [ -n "$5" ] && printf '%s: "%s"\n' "$4" "$5"
    printf -- '---\n\n%s\n' "$6"
  } > "$1/$2/$3"
}
# `out=$(cmd)` is a plain assignment, so errexit is NOT exempt there: the first
# fixture that legitimately exits 1 would kill the run with no failure printed.
run25() { out25="$("$py25" "$t25/check.py" "$1" 2>&1)" && rc25=0 || rc25=$?; }

# Day-one guard: the frontmatter schema differs on purpose (SSOT `globs`,
# mirror `paths`). A byte comparison would fail on every file, so a check that
# flags this pair is checking the wrong thing.
ok25="$t25/ok"
mk25 "$ok25" .agents/rules a.md globs '**/*.sql' '- rule one'
mk25 "$ok25" .claude/rules a.md paths '**/*.sql' '- rule one'
run25 "$ok25"
[ "$rc25" -eq 0 ] || fail "[25] a correctly mirrored pair was reported as drift: $out25"
printf '%s\n' "$out25" | grep -q '\[OK\]' || fail "[25] no OK line for a clean mirror: $out25"

# Reflow is not drift either: blank runs and trailing spaces carry no rule.
rf25="$t25/reflow"
mk25 "$rf25" .agents/rules a.md globs '**/*.sql' '- rule one'
mkdir -p "$rf25/.claude/rules"
printf -- '---\ndescription: x\npaths: "**/*.sql"\n---\n\n\n- rule one   \n\n' > "$rf25/.claude/rules/a.md"
run25 "$rf25"
[ "$rc25" -eq 0 ] || fail "[25] whitespace reflow was reported as drift: $out25"

# The defect this exists for: same name, different rule.
bd25="$t25/body"
mk25 "$bd25" .agents/rules a.md globs '**/*.sql' '- rule one'
mk25 "$bd25" .claude/rules a.md paths '**/*.sql' '- rule TWO'
run25 "$bd25"
[ "$rc25" -ne 0 ] || fail "[25] a differing rule body passed"
printf '%s\n' "$out25" | grep -q '\[MISS\].*body differs' \
  || fail "[25] a differing body was not named as such: $out25"

# Same rule, different scope: it fires on files it was never meant to.
sc25="$t25/scope"
mk25 "$sc25" .agents/rules a.md globs '**/*.sql' '- rule one'
mk25 "$sc25" .claude/rules a.md paths '**/*.py' '- rule one'
run25 "$sc25"
[ "$rc25" -ne 0 ] || fail "[25] a differing scope passed"
printf '%s\n' "$out25" | grep -q '\[MISS\].*scope differs' \
  || fail "[25] a differing scope was not named as such: $out25"

# A rule the SSOT owns that the runtime never sees.
ms25="$t25/missing"
mk25 "$ms25" .agents/rules a.md globs '' '- rule one'
mkdir -p "$ms25/.claude/rules"
run25 "$ms25"
[ "$rc25" -ne 0 ] || fail "[25] a rule with no mirror passed"
printf '%s\n' "$out25" | grep -q '\[MISS\].*no mirror' || fail "[25] missing mirror not named: $out25"

# And the reverse: a rule in the model's context that nothing here owns.
or25="$t25/orphan"
mk25 "$or25" .agents/rules a.md globs '' '- rule one'
mk25 "$or25" .claude/rules a.md paths '' '- rule one'
mk25 "$or25" .claude/rules z.md paths '' '- someone elses rule'
run25 "$or25"
[ "$rc25" -ne 0 ] || fail "[25] an orphan mirror rule passed"
printf '%s\n' "$out25" | grep -q '\[WARN\].*no SSOT behind it' || fail "[25] orphan not named: $out25"

# Not every project is oma-managed, and that is not a fault.
sk25="$t25/skip"; mkdir -p "$sk25"
run25 "$sk25"
[ "$rc25" -eq 0 ] || fail "[25] a non-oma project was treated as a fault: $out25"
printf '%s\n' "$out25" | grep -q '\[SKIP\]' || fail "[25] no SKIP for a non-oma project: $out25"

# But an SSOT with no mirror at all means the runtime loads nothing — the
# quietest possible version of this, and not the same as "nothing to check".
nm25="$t25/nomirror"
mk25 "$nm25" .agents/rules a.md globs '' '- rule one'
run25 "$nm25"
[ "$rc25" -ne 0 ] || fail "[25] an absent mirror tree was reported like a clean project: $out25"
printf '%s\n' "$out25" | grep -q '\[SKIP\]' && fail "[25] an absent mirror tree was skipped instead of reported"

echo "[26] a hook whose gate can never be true is dead, and doctor says so"
# doctor validated ~/.claude/settings.json and never opened the project's own
# .claude/settings.json. The project file held a PreToolUse hook that fires on
# every rg/grep to point the model at the graphify graph — gated on
# `[ -f graphify-out/graph.json ]`, a file that exists in no checkout here. It
# ran thousands of times and exited silently every one of them. Registered and
# firing are different, and only the first was being checked.
t26="$TMP/project-hooks"; mkdir -p "$t26"
awk '/echo "\[ Project hooks/{sec=1} sec && /^import /{grab=1} grab && /^PYEOF$/{exit} grab' \
  "$ROOT/lib/doctor/claude.sh" > "$t26/check.py"
grep -q 'GATE = re.compile' "$t26/check.py" \
  || fail "[26] could not extract the project-hook check from lib/doctor/claude.sh"
py26="$(command -v python3)"

mk26() { # mk26 <root> <command-string>
  mkdir -p "$1/.claude"
  "$py26" - "$1/.claude/settings.json" "$2" <<'PY'
import json, sys
json.dump({"hooks": {"PreToolUse": [{"hooks": [{"command": sys.argv[2]}]}]}},
          open(sys.argv[1], "w"))
PY
}
run26() { out26="$("$py26" "$t26/check.py" "$1" 2>&1)" && rc26=0 || rc26=$?; }

# The defect itself: a gate on a path that is not there.
d26="$t26/dead"; mk26 "$d26" 'case "$CMD" in *rg*) [ -f graphify-out/graph.json ] && echo hi ;; esac'
run26 "$d26"
[ "$rc26" -ne 0 ] || fail "[26] a hook gated on a missing file passed: $out26"
printf '%s\n' "$out26" | grep -q '\[DEAD\].*graphify-out/graph.json' \
  || fail "[26] the dead gate was not named: $out26"

# Same hook, gate satisfied — must flip. Without this the check could be
# reporting DEAD unconditionally and nobody would know.
l26="$t26/live"; mk26 "$l26" '[ -f graphify-out/graph.json ] && echo hi'
mkdir -p "$l26/graphify-out"; echo '{}' > "$l26/graphify-out/graph.json"
run26 "$l26"
[ "$rc26" -eq 0 ] || fail "[26] a satisfied gate was still reported dead: $out26"
printf '%s\n' "$out26" | grep -q '\[OK\].*is satisfied' || fail "[26] no OK for a live gate: $out26"

# -d gates are gates too.
dir26="$t26/dirgate"; mk26 "$dir26" '[ -d .agents/rules ] && echo hi'
run26 "$dir26"
[ "$rc26" -ne 0 ] || fail "[26] a -d gate on a missing directory passed"
mkdir -p "$dir26/.agents/rules"
run26 "$dir26"
[ "$rc26" -eq 0 ] || fail "[26] a -d gate on an existing directory was reported dead: $out26"

# $CLAUDE_PROJECT_DIR is the one variable the runtime guarantees; resolving it
# is the difference between checking the hook and giving up on it.
cp26="$t26/projdir"; mk26 "$cp26" '[ -f "$CLAUDE_PROJECT_DIR/.claude/settings.json" ] && echo hi'
run26 "$cp26"
[ "$rc26" -eq 0 ] || fail "[26] \$CLAUDE_PROJECT_DIR was not resolved: $out26"

# Any other variable cannot be resolved from here — and "cannot check" must not
# print like "passed". This is the lesson the codex dep check paid for.
uv26="$t26/unexpanded"; mk26 "$uv26" '[ -f "$SOME_OTHER_DIR/x.json" ] && echo hi'
run26 "$uv26"
[ "$rc26" -ne 0 ] || fail "[26] an unresolvable gate was treated as passing: $out26"
printf '%s\n' "$out26" | grep -q '\[WARN\].*unexpanded' || fail "[26] unexpanded var not named: $out26"

# Absent file and hook-free file are both "nothing to check", not faults.
none26="$t26/none"; mkdir -p "$none26"
run26 "$none26"
[ "$rc26" -eq 0 ] || fail "[26] a project with no settings.json was a fault: $out26"
printf '%s\n' "$out26" | grep -q '\[SKIP\]' || fail "[26] no SKIP without settings.json: $out26"

empty26="$t26/empty"; mkdir -p "$empty26/.claude"; echo '{"hooks":{}}' > "$empty26/.claude/settings.json"
run26 "$empty26"
[ "$rc26" -eq 0 ] || fail "[26] a hook-free settings.json was a fault: $out26"

# But an unreadable settings.json is not "no hooks" — it is "not checked".
bad26="$t26/broken"; mkdir -p "$bad26/.claude"; printf '{not json' > "$bad26/.claude/settings.json"
run26 "$bad26"
[ "$rc26" -ne 0 ] || fail "[26] unreadable settings.json reported like a clean project: $out26"
printf '%s\n' "$out26" | grep -q '\[WARN\].*unreadable' || fail "[26] unreadable not named: $out26"

# A hook with no file gate is not dead — it is simply outside what this reads.
ng26="$t26/nogate"; mk26 "$ng26" 'echo always-runs'
run26 "$ng26"
[ "$rc26" -eq 0 ] || fail "[26] a gate-free hook was reported as a fault: $out26"
printf '%s\n' "$out26" | grep -q '\[NOTE\].*no file gate' || fail "[26] gate-free hook not counted: $out26"

echo "[27] the uptake ledger tells a missing counter apart from a zero one"
# symbol-search-gate.js was retired 2026-08-14, so rows written after it carry
# no `gate` key at all. Summing those with a .get(k, 0) prints "denials: 0",
# which reads as "the gate ran and never fired" — the same key-absent-vs-value-
# absent confusion that misdiagnosed the serena config twice during that
# investigation (a config with `language_servers:` and no `languages:` key was
# read as "languages is empty"). This ledger exists to say what was measured,
# so it must not answer "not recorded" with a number.
t27="$TMP/uptake-trend"; mkdir -p "$t27/new" "$t27/old" "$t27/mix"
NEW27='{"ts":"2026-08-15T00:00:00Z","session":"a","cwd":"/p","calls":10,"nav":{"rg":5,"serena":2}}'
OLD27='{"ts":"2026-08-01T00:00:00Z","session":"b","cwd":"/p","calls":10,"nav":{"rg":5,"serena":0},"gate":{"denied":0,"escape":0}}'
printf '%s\n' "$NEW27" > "$t27/new/rows.jsonl"
printf '%s\n' "$OLD27" > "$t27/old/rows.jsonl"
printf '%s\n%s\n' "$NEW27" "$OLD27" > "$t27/mix/rows.jsonl"

run27() { OMA_UPTAKE_DIR="$t27/$1" bash "$ROOT/scripts/measure-uptake.sh" trend 2>&1; }

out27="$(run27 new)"
printf '%s\n' "$out27" | grep -q 'no data in window' \
  || fail "[27] rows without a gate key did not say so: $out27"
# The bug this pins: printing a zero for a counter nothing produces.
printf '%s\n' "$out27" | grep -q 'denials' \
  && fail "[27] a denial count was printed for rows that carry no gate key"

# A row that DOES carry the key must still be rendered — retiring the producer
# must not erase what was already measured.
out27="$(run27 old)"
printf '%s\n' "$out27" | grep -q 'denials *: *0' \
  || fail "[27] a row carrying gate.denied=0 was not rendered: $out27"
printf '%s\n' "$out27" | grep -q 'no data in window' \
  && fail "[27] a row carrying the gate key was reported as no data"

# Mixed window: the denominator has to be the carrying rows, not all rows, or
# every rate silently halves as new rows accumulate.
out27="$(run27 mix)"
printf '%s\n' "$out27" | grep -q 'rows carrying gate\.\* *: *1 of 2' \
  || fail "[27] mixed window did not name how many rows carried the key: $out27"

# The gate was kept on one prediction: narrowing it to single-symbol lookups
# drops the escape share below the 54% that motivated the narrowing. The gate
# reached 28 firings at 54% before anyone looked, so the prediction is checked
# by this script rather than left as an intention. Three boundaries, because a
# verdict that cannot say "not yet" will say "pass" while the sample is empty.
mk27() { # mk27 <dir> <to_escape> <to_serena>
  mkdir -p "$t27/$1"
  printf '{"ts":"2026-08-20T00:00:00Z","session":"s","cwd":"/p","calls":9,"nav":{"rg":1},"gate":{"denied":%d,"escape":%d,"to_escape":%d,"to_serena":%d}}\n' \
    "$(( $2 + $3 ))" "$2" "$2" "$3" > "$t27/$1/rows.jsonl"
}
mk27 sun-few 3 2                       # 5 firings — under the threshold
out27="$(run27 sun-few)"
printf '%s\n' "$out27" | grep -qi 'undecided' \
  || fail "[27] a sample too small to judge was not reported as undecided: $out27"

mk27 sun-bad 15 10                     # 25 firings, 60% escape — worse than baseline
out27="$(run27 sun-bad)"
printf '%s\n' "$out27" | grep -q 'NOT BELOW BASELINE' \
  || fail "[27] an escape share at/above baseline did not trip the sunset: $out27"
# Two separate lines, asserted separately. A single alternation over both was
# the first version and it let a mutation deleting one of them survive: the
# word it matched was still present in the other line. A verdict has to say
# BOTH that the gate should go and where to go to remove it.
printf '%s\n' "$out27" | grep -q 'Retire it' \
  || fail "[27] the sunset tripped without saying to retire the gate: $out27"
printf '%s\n' "$out27" | grep -q 'manifest\.json' \
  || fail "[27] the sunset said to retire the gate without naming where: $out27"

mk27 sun-ok 4 21                       # 25 firings, 16% escape — narrowing holding
out27="$(run27 sun-ok)"
printf '%s\n' "$out27" | grep -q 'holding' \
  || fail "[27] an escape share below baseline was not reported as holding: $out27"
printf '%s\n' "$out27" | grep -q 'NOT BELOW BASELINE' \
  && fail "[27] a passing escape share still tripped the sunset"

# The same key-absent-vs-zero rule, applied to nav.serena_err — which the first
# version of this step did NOT cover, so the discipline was only half installed.
# Measured on the real ledger: 72 rows, 13 with serena calls, and exactly 0 of
# those 13 carrying serena_err (the field landed later that day). trend printed
# "serena calls that errored: 0 / 28 (0%)" while the transcripts showed 10 of
# those calls returning "No active project" — a 100% failure rate rendered as 0%.
mkdir -p "$t27/err-absent" "$t27/err-present"
printf '{"ts":"2026-08-10T00:00:00Z","session":"e1","cwd":"/p","calls":5,"nav":{"rg":3,"serena":4}}\n' \
  > "$t27/err-absent/rows.jsonl"
out27="$(run27 err-absent)"
printf '%s\n' "$out27" | grep -qE 'errored.*0 / 4|errored.*\(0%\)' \
  && fail "[27] rows with serena calls but no serena_err key were rendered as a 0% error rate: $out27"
# The wording is the deliverable: "not recorded" and "0%" must not be
# interchangeable in this ledger. Anchored to the serena line — a bare
# 'not recorded' matched the gate section's own "(not recorded; not zero
# firings)" further up the report, so the mutant that deleted this branch
# passed on a phrase from a different verdict entirely.
printf '%s\n' "$out27" | grep -q 'serena calls:.*not recorded' \
  || fail "[27] unrecorded serena errors were not called unrecorded: $out27"

# The shape the real ledger is in: SOME rows carry the field, others do not, and
# the serena calls live in the rows that do not. Without this fixture the two
# guards mask each other — restricting the denominator and special-casing the
# all-absent window each looked unnecessary on their own.
mkdir -p "$t27/err-mixed"
{ printf '{"ts":"2026-08-10T00:00:00Z","session":"m1","cwd":"/p","calls":5,"nav":{"rg":3,"serena":4}}\n'
  printf '{"ts":"2026-08-14T00:00:00Z","session":"m2","cwd":"/p","calls":5,"nav":{"rg":3,"serena":2,"serena_err":1}}\n'
} > "$t27/err-mixed/rows.jsonl"
out27="$(run27 err-mixed)"
printf '%s\n' "$out27" | grep -qE 'errored: 1 / 2' \
  || fail "[27] the error rate was not computed over the rows that record errors: $out27"
printf '%s\n' "$out27" | grep -qE 'errored: 1 / 6' \
  && fail "[27] calls from rows with no error field were counted in the denominator"

printf '{"ts":"2026-08-14T00:00:00Z","session":"e2","cwd":"/p","calls":5,"nav":{"rg":3,"serena":4,"serena_err":4}}\n' \
  > "$t27/err-present/rows.jsonl"
out27="$(run27 err-present)"
printf '%s\n' "$out27" | grep -qE 'errored.*4 / 4|100%' \
  || fail "[27] a row recording that every serena call failed did not report it: $out27"

echo "[28] the coding rules are reachable from a project that is not this checkout"
# Reported from a worktree: "코드 작성 규칙을 못 찾는데". It was not a bug in
# that repo — .claude/rules/*.md (backend, quality, debug, database, frontend…)
# live in THIS checkout only, and the assembled global file carries rules/*.md
# (process rules) plus tools.md and nothing else. So in any other directory the
# coding standards simply do not exist, by design.
#
# Every test in this suite runs inside this checkout, which is why none of them
# could see it: a check that only ever looks here cannot find what is missing
# everywhere else. The assertion is therefore about the GLOBAL artifact — the
# one file that is present in every project — and it names each rule by its
# absolute path, so following the pointer does not depend on the reader's cwd.
t28="$TMP/global-rules"; mkdir -p "$t28"
(
  SCRIPT_DIR="$ROOT" CONFIG_DIR="$t28/claude" CODEX_DIR="$t28/codex" GEMINI_DIR="$t28/gemini"
  export SCRIPT_DIR CONFIG_DIR CODEX_DIR GEMINI_DIR
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh" 2>/dev/null || true
  assemble_global_rules
) >/dev/null 2>&1 || true
# Judged by the artifact, not the subshell's status: log_and_print writes to a
# log path this harness does not set up here, so the exit code reports the
# logging, not the assembly. Asserting on the status was the first version and
# it failed for that reason while the assembly had in fact succeeded.
g28="$t28/claude/CLAUDE.md"
[ -f "$g28" ] || fail "[28] no global instruction file was assembled"

missing28=""
for r in "$ROOT"/.claude/rules/*.md; do
  [ -f "$r" ] || continue
  grep -qF "$r" "$g28" || missing28="$missing28 $(basename "$r")"
done
[ -z "$missing28" ] \
  || fail "[28] the global file names no path for:$missing28 — these rules are unreachable outside this checkout"

# A pointer to a file that is not there is worse than no pointer: it reads as
# coverage. Every path the index offers has to resolve.
while IFS= read -r p28; do
  [ -e "$p28" ] || fail "[28] the global file points at a rule that does not exist: $p28"
done < <(grep -oE "$ROOT/\.claude/rules/[A-Za-z0-9._-]+\.md" "$g28" | sort -u)

# Absolute, not relative: the reader is in another repo, so a relative path
# resolves against the wrong root — the same cwd assumption that left the
# graphify hook pointing at a graph.json no checkout here has.
grep -qE '(^|[^A-Za-z0-9_./-])\.claude/rules/' "$g28" \
  && fail "[28] the index offers a cwd-relative rule path"

# The scope cell is read out of the project CLAUDE.md, whose rule table is not
# the only table with a `| debug |` row — the workflow table has one too, and
# the first version of this index advertised debug.md as applying to "Root cause
# + minimal fix". A scope has to be one of the shapes that table actually uses,
# or the index is quietly describing a different document.
while IFS= read -r sc28; do
  case "$sc28" in
    always|"on request"|'**/*'*) ;;
    *) fail "[28] rule index carries a scope that is not a real scope: '$sc28'" ;;
  esac
done < <(sed -n '/^| 규칙 | 적용 시점 |/,/^$/p' "$g28" \
           | sed -n 's/^| *[^|]* *| *\([^|]*[^| ]\) *|.*/\1/p' \
           | grep -v '^적용 시점$' | grep -v '^-\+$')

# A checkout with no rule directory must emit nothing, not a heading over an
# empty table — an index that lists no rules reads as "there are none", which is
# the same false reassurance this whole step exists to remove.
empty28="$TMP/no-rules"; mkdir -p "$empty28"
out28="$(
  SCRIPT_DIR="$empty28"; export SCRIPT_DIR
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh" 2>/dev/null || true
  emit_rule_index 2>/dev/null
)"
[ -z "$out28" ] || fail "[28] a checkout with no .claude/rules emitted an index anyway: $out28"

echo "[29] a code graph is judged by how stale it is, not by whether the tool installed"
# Measured on the research worktree: the CRG graph was built at 0c0ebdcd while
# HEAD was 785f565f — 351 commits and 51 changed source files later, including
# every directory that work actually touched. doctor reported nothing, because
# what it checks is that the `graphify` command exists and that SKILL.md is on
# disk. Installed is stage one of five; this is the same shape as the serena
# configs that were present, prescribed, and unloadable.
#
# A stale graph is worse than an absent one: absent is obvious, stale answers
# confidently about code that no longer exists.
gf29="$ROOT/lib/doctor/graph-freshness.sh"
[ -x "$gf29" ] || fail "[29] no graph freshness check ships (expected $gf29)"

mkrepo29() { # mkrepo29 <dir>  -> a git repo with one commit
  mkdir -p "$1"; ( cd "$1" && git init -q . && git config user.email t@t && git config user.name t \
    && echo x > f.py && git add f.py && git commit -qm one ) >/dev/null 2>&1
}
run29() { bash "$gf29" "$@" 2>&1; }

# absent: the tool never produced anything here. Named, because "no output" is
# how graphify stayed dead in every checkout for its whole life.
r29a="$TMP/g29/absent"; mkrepo29 "$r29a"
out29="$(run29 "$r29a")"
printf '%s\n' "$out29" | grep -q '\[MISS\]' \
  || fail "[29] a repo with no graph at all was not reported: $out29"

# stale: artifact older than HEAD. The count is the point — "stale" without a
# magnitude reads as a nit, and 351 is not a nit.
r29s="$TMP/g29/stale"; mkrepo29 "$r29s"
mkdir -p "$r29s/graphify-out"; echo '{}' > "$r29s/graphify-out/graph.json"
touch -d '2020-01-01' "$r29s/graphify-out/graph.json"
( cd "$r29s" && echo y >> f.py && git commit -qam two ) >/dev/null 2>&1
out29="$(run29 "$r29s")"
printf '%s\n' "$out29" | grep -q '\[STALE\]' \
  || fail "[29] a graph older than HEAD was not reported stale: $out29"
printf '%s\n' "$out29" | grep -qE '\[STALE\].*[0-9]+ commit' \
  || fail "[29] staleness was reported without saying how far behind: $out29"

# fresh: no warning, or the check cries wolf and gets ignored like every other
# channel this harness measured at 0-5%.
r29f="$TMP/g29/fresh"; mkrepo29 "$r29f"
mkdir -p "$r29f/graphify-out"; echo '{}' > "$r29f/graphify-out/graph.json"
out29="$(run29 "$r29f")"
printf '%s\n' "$out29" | grep -q '\[OK\]' \
  || fail "[29] a graph newer than HEAD was not reported healthy: $out29"
printf '%s\n' "$out29" | grep -q '\[STALE\]' \
  && fail "[29] a fresh graph was reported stale"

# The false green this check shipped with: a CRG database records the commit it
# was built from, and reading that database rewrites its mtime. On the machine
# that prompted this, a graph 351 commits old reported itself current the first
# time the check ran, because the file had just been opened. The recorded commit
# is the only honest basis; mtime is the fallback for graphify, which records
# nothing.
r29d="$TMP/g29/mtime-lies"; mkrepo29 "$r29d"
old29="$(git -C "$r29d" rev-parse HEAD)"
( cd "$r29d" && echo z >> f.py && git commit -qam two && echo w >> f.py && git commit -qam three ) >/dev/null 2>&1
mkdir -p "$r29d/.code-review-graph"
python3 - "$r29d/.code-review-graph/graph.db" "$old29" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table metadata (key text, value text)")
con.execute("insert into metadata values ('git_head_sha', ?)", (sys.argv[2],))
con.commit()
PY
# Freshly touched: mtime alone would call this current.
touch "$r29d/.code-review-graph/graph.db"
out29="$(run29 "$r29d")"
printf '%s\n' "$out29" | grep -qE '\[STALE\].*2 commit' \
  || fail "[29] a graph whose recorded commit is 2 behind was judged by mtime instead: $out29"
printf '%s\n' "$out29" | grep -q 'recorded commit' \
  || fail "[29] the verdict did not say it used the recorded commit: $out29"

# graphify writes the graph UNDER the path it was given, so
# `graphify update src/foo` leaves src/foo/graphify-out/graph.json and only a
# cache manifest at the cwd. Judging by the repo-root path alone called that a
# MISS forever — measured on the worktree, where a scoped build of 865 nodes was
# reported as "no graph at all". A scoped graph is not the same as a root graph
# and should not be called [OK], but calling it missing is worse: it tells the
# operator to redo work that is already done.
r29g="$TMP/g29/scoped"; mkrepo29 "$r29g"
# Nested as deep as the real one (find reports this file at level 7). A
# -maxdepth 6 version of the search passed every other assertion here and
# missed exactly this path on the real machine.
mkdir -p "$r29g/src/boltz/model/potentials/swarm/graphify-out"
echo '{}' > "$r29g/src/boltz/model/potentials/swarm/graphify-out/graph.json"
out29="$(run29 "$r29g")"
printf '%s\n' "$out29" | grep -q 'potentials/swarm/graphify-out' \
  || fail "[29] a scoped graph elsewhere in the tree was not mentioned: $out29"
printf '%s\n' "$out29" | grep -qE '\[MISS\].*no graphify-out/graph.json' \
  && fail "[29] a repo holding a scoped graph was still reported as having none"

# The harness tells the model to run `graphify update .`; doing so drops
# graphify-out/ into the repo root. With no ignore entry that is untracked
# noise in someone else's project, which is why it has not been run.
out29="$(run29 "$r29f")"
printf '%s\n' "$out29" | grep -qi 'ignore' \
  || fail "[29] an unignored graph artifact was not flagged as git pollution: $out29"
printf 'graphify-out/\n' > "$r29f/.gitignore"
out29="$(run29 "$r29f")"
printf '%s\n' "$out29" | grep -qi 'ignore' \
  && fail "[29] an already-ignored artifact was still flagged"

# One checkout arrives three ways — as SCRIPT_DIR, as the cwd git root, and as a
# registered serena project — and on the real machine it printed three identical
# verdicts, which reads as three repos in trouble. Seen once on stdout, not
# noticed by any assertion until a mutation removing the dedupe survived.
out29="$(run29 "$r29f" "$r29f" "$r29f/.")"
[ "$(printf '%s\n' "$out29" | grep -c 'graphify-out/graph.json')" = 1 ] \
  || fail "[29] the same repo was reported once per path it was named by: $out29"

echo "[30] every graphify command this harness prescribes exists in the installed CLI"
# Stated as "does the prescribed command exist", not as a list of banned words.
# The first version banned `query` because a truncated `--help | head -20` did
# not reach line 29, where `query` is in fact documented — the fifth measurement
# error of this investigation and the same one every time: a cut-off listing read
# as the whole listing. An existence check against the live CLI cannot be fooled
# that way, and it also catches the real risk here, which is upstream renaming a
# subcommand out from under text this harness ships into every project.
sec30="$(sed -n '/graphify update\|^- For cross-module/p' "$ROOT/lib/common.sh")"
[ -n "$sec30" ] || fail "[30] could not find the graphify guidance in lib/common.sh"
if command -v graphify >/dev/null 2>&1; then
  help30="$(graphify --help 2>&1 || true)"
  # Whole output, never piped through head: truncating the evidence is the bug.
  for verb in $(printf '%s\n' "$sec30" | grep -oE 'graphify [a-z-]+' | awk '{print $2}' | sort -u); do
    printf '%s\n' "$help30" | grep -qE "^[[:space:]]+$verb([[:space:]]|$)" \
      || fail "[30] harness prescribes 'graphify $verb' but the installed CLI has no such subcommand"
  done
else
  echo "  (graphify not installed — command existence unverified)"
fi

# Correcting the text is useless if it never reaches a project that already has
# the old one. append_section_if_missing saw its marker and printed
# "already has graphify" — so a project seeded with the wrong command keeps it
# forever, which is the same shape as a hook that is registered and never fires.
t30="$TMP/section-refresh"; mkdir -p "$t30"
(
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh" 2>/dev/null || true
  # Content on BOTH sides of the section. Only leading content was pinned at
  # first, and a mutant that let the replacement run to end-of-file survived:
  # it would have eaten every project rule written after the graphify block.
  printf '# proj\n\nkeep-before\n\n## graphify\n\nold body stale-marker\n\n## project rules\n\nkeep-after\n' \
    > "$t30/CLAUDE.md"
  append_section_if_missing "$t30/CLAUDE.md" "## graphify" "## graphify

new body"
) >/dev/null 2>&1 || true
grep -q 'new body' "$t30/CLAUDE.md" \
  || fail "[30] a project that already had the section never received the corrected text"
[ "$(grep -c '^## graphify' "$t30/CLAUDE.md")" = 1 ] \
  || fail "[30] refreshing the section duplicated it: $(grep -c '^## graphify' "$t30/CLAUDE.md") copies"
grep -q 'stale-marker' "$t30/CLAUDE.md" \
  && fail "[30] the stale body survived the refresh"
for keep in keep-before keep-after '## project rules'; do
  grep -qF "$keep" "$t30/CLAUDE.md" \
    || fail "[30] refreshing the section ate '$keep' — content outside it is the project's, not ours"
done

echo "[31] the ledger counts a session once, however many times it ended"
# uptake-record.js takes p.transcript_path and rescans that ONE file from the
# top on every SessionEnd (uptake-record.js:143-153 — no cursor, no delta), then
# appends. A session that ends more than once (exit, clear, logout,
# prompt_input_exit, resume) therefore contributes several CUMULATIVE snapshots
# of the same growing transcript, and `trend` summed them as if they were
# disjoint. Measured on the real ledger: 72 rows over 50 distinct sessions, one
# session holding 10 rows, every multi-row session monotonic non-decreasing
# (0 of 6 with a falling counter). The overcount that reached this session's own
# conclusions: rg 9,703 vs 3,064 (+217%), serena 28 vs 8 (+250%), graphify 168
# vs 56 (+200%), ToolSearch 714 vs 254 (+181%), calls 45,455 vs 14,096.
#
# Both the producer comment (uptake-record.js:2) and the manifest entry claimed
# "one behavioural row per session", so the consumer was written to a contract
# the producer never kept. This pins the arithmetic, not the prose.
t31="$TMP/uptake-sessions"; mkdir -p "$t31/dup" "$t31/back"
# One session, three snapshots of the same transcript as it grew, plus a second
# session with one row. Correct answer: 2 sessions, serena 4+1=5, rg 12+2=14,
# calls 30+5=35. Summing rows gives serena 10, rg 28, calls 65.
{
  printf '{"ts":"2026-08-20T01:00:00Z","session":"dup","cwd":"/p","reason":"prompt_input_exit","calls":10,"nav":{"rg":5,"serena":2}}\n'
  printf '{"ts":"2026-08-20T02:00:00Z","session":"dup","cwd":"/p","reason":"other","calls":20,"nav":{"rg":9,"serena":3}}\n'
  printf '{"ts":"2026-08-20T03:00:00Z","session":"dup","cwd":"/p","reason":"other","calls":30,"nav":{"rg":12,"serena":4}}\n'
  printf '{"ts":"2026-08-20T04:00:00Z","session":"solo","cwd":"/p","reason":"other","calls":5,"nav":{"rg":2,"serena":1}}\n'
} > "$t31/dup/rows.jsonl"

run31() { OMA_UPTAKE_DIR="$t31/$1" bash "$ROOT/scripts/measure-uptake.sh" trend 2>&1; }
out31="$(run31 dup)"

# The collapse has to be stated. A number that silently changed meaning is how
# the wrong totals got quoted as evidence in the first place.
printf '%s\n' "$out31" | grep -qE 'sessions *: *2\b' \
  || fail "[31] four rows over two sessions were not reported as 2 sessions: $out31"
printf '%s\n' "$out31" | grep -q '4 rows' \
  || fail "[31] the collapse did not say how many rows it read: $out31"

# The three totals that were inflated. Asserted separately: a single alternation
# over them let a mutation deleting one survive, because the digits it matched
# were still present in another line.
printf '%s\n' "$out31" | grep -qE 'serena +2 +100\.0% +5\b' \
  || fail "[31] serena was not 5 (per-session latest) — summed rows give 10: $out31"
printf '%s\n' "$out31" | grep -qE 'rg/grep +2 +100\.0% +14\b' \
  || fail "[31] rg was not 14 (per-session latest) — summed rows give 28: $out31"
printf '%s\n' "$out31" | grep -qE 'total tool calls *: *35\b' \
  || fail "[31] tool calls were not 35 (per-session latest) — summed rows give 65: $out31"

# A rate is per session, so a channel used in both sessions is 100%, not 50%
# (which is what 2 carrying rows out of 4 would print).
printf '%s\n' "$out31" | grep -q '50\.0%' \
  && fail "[31] a rate was still computed over rows instead of sessions: $out31"

# Robustness, not a claim about the data: every multi-row session measured was
# monotonic, but a transcript can lose records to compaction. If a later
# snapshot is lower, the aggregate must not fall with it — otherwise a compacted
# session silently reports less work than it was already known to have done.
{
  printf '{"ts":"2026-08-21T01:00:00Z","session":"back","cwd":"/p","reason":"other","calls":40,"nav":{"rg":20,"serena":6}}\n'
  printf '{"ts":"2026-08-21T02:00:00Z","session":"back","cwd":"/p","reason":"other","calls":7,"nav":{"rg":3,"serena":1}}\n'
} > "$t31/back/rows.jsonl"
out31="$(run31 back)"
printf '%s\n' "$out31" | grep -qE 'serena +1 +100\.0% +6\b' \
  || fail "[31] a later, lower snapshot pulled the session total down: $out31"
printf '%s\n' "$out31" | grep -qE 'total tool calls *: *40\b' \
  || fail "[31] a later, lower snapshot pulled the call total down: $out31"

# The producer's own description has to stop promising one row per session, or
# the next reader writes the same summation again.
grep -q 'one behavioural row per session' "$ROOT/runtimes/claude/hooks/uptake-record.js" \
  && fail "[31] uptake-record.js still claims one row per session; it writes one per SessionEnd"
grep -q 'one behavioural row per session' "$ROOT/runtimes/claude/hooks/manifest.json" \
  && fail "[31] manifest.json still claims one row per session; it writes one per SessionEnd"

echo "smoke-refactor OK"
