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
import json, sys
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

echo "[10] lab experiment tools (throwaway git repo)"
# All four tools run against a temp repo, never this one: they write .oma-lab/
# into whatever repo they are invoked from.
lab_repo="$TMP/labrepo"; mkdir -p "$lab_repo"
(
  cd "$lab_repo"
  git init -q -b main && git config user.email t@t && git config user.name t
  printf 'lr: 1e-3\n' > config.yaml && git add -A && git commit -qm init

  O() { bash "$ROOT/scripts/oma-lab" "$@"; }

  # ledger: records, mirrors the exit code, and refuses to launch behind a
  # failing gate — the property that saves the GPU hours.
  O run --metrics 'rmse=0.42' -- python3 -c 'print(1)' >/dev/null 2>&1 || exit 1
  O run -- python3 -c 'raise SystemExit(7)' >/dev/null 2>&1
  [ "$?" = 7 ] || { echo "ledger did not mirror the command exit code"; exit 1; }

  mkdir -p scripts
  printf '#!/usr/bin/env bash\nexit 1\n' > scripts/check.sh && chmod +x scripts/check.sh
  O run -- python3 -c "open('SHOULD_NOT_EXIST','w')" >/dev/null 2>&1
  [ ! -e SHOULD_NOT_EXIST ] || { echo "failing gate did not stop the launch"; exit 1; }
  O run --no-gate -- python3 -c 'print(1)' >/dev/null 2>&1 \
    && { echo "--no-gate was accepted without --reason"; exit 1; }
  rm -f scripts/check.sh

  # fail: an unchanged retry is refused, a retry after edits is only warned.
  O fail record --cmd 'python train.py' --exit 1 >/dev/null 2>&1
  O fail check --cmd 'python   train.py' >/dev/null 2>&1
  [ "$?" = 3 ] || { echo "fail-ledger did not refuse an unchanged retry"; exit 1; }
  printf 'edit\n' >> config.yaml
  O fail check --cmd 'python train.py' >/dev/null 2>&1 || { echo "fail-ledger blocked a retry after edits"; exit 1; }

  # board: a second claim is refused, and a running experiment is never
  # reclaimed no matter how stale the TTL says it is.
  O board claim --id e1 >/dev/null 2>&1 || { echo "first claim failed"; exit 1; }
  O board claim --id e1 >/dev/null 2>&1 && { echo "duplicate claim was allowed"; exit 1; }
  O board start --id e1 --job 0012345 >/dev/null 2>&1
  OMA_BOARD_CLAIM_TTL=0 O board claim --id e1 >/dev/null 2>&1 \
    && { echo "a running experiment was reclaimed"; exit 1; }
  O board list 2>/dev/null | grep -q '0012345' || { echo "job id lost its leading zero"; exit 1; }
  O board finish --id e1 --result ok >/dev/null 2>&1
  O board claim --id e1 >/dev/null 2>&1 || { echo "could not reclaim a finished id"; exit 1; }

  # capsule: an output is traceable back to the run that wrote it.
  O run -- python3 -c "open('ckpt.pt','w').write('v1')" >/dev/null 2>&1
  O capsule save --config config.yaml --output ckpt.pt --note v1 >/dev/null 2>&1
  O capsule whence ckpt.pt >/dev/null 2>&1 || { echo "whence could not find a saved output"; exit 1; }
  echo unrelated > other.pt
  O capsule whence other.pt >/dev/null 2>&1 && { echo "whence matched a file it never saw"; exit 1; }

  # State stays in the project and git ignores it — via .git/info/exclude, so
  # the user's tracked .gitignore never grows harness residue.
  [ -d .oma-lab ] || { echo ".oma-lab not created"; exit 1; }
  grep -qxF '.oma-lab/' .git/info/exclude || { echo ".oma-lab/ not excluded"; exit 1; }
  [ ! -e .gitignore ] || { echo "the tools created or edited .gitignore"; exit 1; }
  [ -z "$(git status --porcelain | grep oma-lab)" ] || { echo ".oma-lab is visible to git"; exit 1; }
) || fail "lab experiment tools regressed"
# and nothing leaked into this repo
test ! -e "$ROOT/.oma-lab" || fail "lab tools wrote into the harness repo"

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
  # can actually be provoked: tests/lab-e2e.sh json-parses fail-ledger's
  # additionalContext (verified — corrupting that write fails lab e2e), and
  # runtimes/claude/hooks/test-pre-edit-gate.js covers the edit gate.
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

echo "smoke-refactor OK"
