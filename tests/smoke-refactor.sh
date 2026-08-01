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
for h in json.loads(manifest.read_text())["hooks"]:
    if sum(h["script"] in c for c in cmds) != 1:
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
  write_managed_block "$mb/half.md" "$mb/body2" >/dev/null
  cmp -s "$mb/half.before" "$mb/half.md" || { echo "half-marked file was rewritten"; exit 1; }
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

echo "smoke-refactor OK"
