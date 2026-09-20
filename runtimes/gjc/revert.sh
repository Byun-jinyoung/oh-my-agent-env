#!/usr/bin/env bash
# Revert the GJC features deployed by `setup.sh sync` (sync_gjc_hooks /
# sync_gjc_settings) and the harness project override.
#
# Usage:
#   runtimes/gjc/revert.sh [--settings] [--dry-run] [--yes]
#     (default)   remove ONLY the attitude-gate hooks + their seeded config +
#                 the harness .gjc/config.yml override. Leaves your GJC
#                 compaction/memory tuning in place.
#     --settings  ALSO remove the compaction/contextPromotion/memory/memories
#                 blocks this repo added to ~/.gjc/agent/config.yml, restoring
#                 GJC defaults for those keys. Your other settings (modelRoles,
#                 task, theme, …) are preserved.
#     --dry-run   print what would change; touch nothing.
#     --yes       skip the confirmation prompt.
#
# Every mutated file is backed up to <file>.revert-bak.<timestamp> first, so the
# revert is itself reversible.
set -u

DRY=0; SETTINGS=0; YES=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --settings) SETTINGS=1 ;;
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

AGENT_DIR="${GJC_CODING_AGENT_DIR:-$HOME/.gjc/agent}"
HOOKS_DIR="$AGENT_DIR/hooks/pre"
HOOK_CFG="$AGENT_DIR/hooks/attitude-gate.json"
GLOBAL_CFG="$AGENT_DIR/config.yml"
# Harness project override lives at the repo root (this script is runtimes/gjc/revert.sh).
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS_CFG="$REPO_ROOT/.gjc/config.yml"
TS="$(date +%Y%m%d-%H%M%S)"

ATTITUDE_HOOKS=(_gate.ts write.ts edit.ts bash.ts)
REMOVE_BLOCKS=(compaction contextPromotion memory memories)
DRY_TAG=""; [ "$DRY" -eq 1 ] && DRY_TAG=" (dry-run)"

say() { printf '%s\n' "$*"; }
act() { # act <description> <command...>
  local desc="$1"; shift
  if [ "$DRY" -eq 1 ]; then say "  [dry-run] $desc"; else "$@" && say "  [done] $desc" || say "  [skip] $desc (not present or failed)"; fi
}

# Remove one top-level YAML block (key: + its indented children) in place.
strip_blocks() {
  local file="$1"; shift
  python3 - "$file" "$@" <<'PY'
import sys
path, keys = sys.argv[1], set(sys.argv[2:])
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
out, skip = [], False
for ln in lines:
    stripped = ln.rstrip("\n")
    is_top = stripped[:1] not in (" ", "\t", "") and ":" in stripped
    if is_top:
        key = stripped.split(":", 1)[0].strip()
        skip = key in keys
    if not skip:
        out.append(ln)
open(path, "w", encoding="utf-8").write("".join(out))
PY
}

say "GJC feature revert$DRY_TAG"
say "  agent dir : $AGENT_DIR"
say "  scope     : hooks$([ "$SETTINGS" -eq 1 ] && echo ' + settings')"

if [ "$DRY" -eq 0 ] && [ "$YES" -eq 0 ]; then
  printf 'Proceed? [y/N] '; read -r ans; case "$ans" in y|Y) ;; *) say "aborted."; exit 0 ;; esac
fi

# 1) attitude-gate hooks (remove only the files this repo installs)
for h in "${ATTITUDE_HOOKS[@]}"; do
  f="$HOOKS_DIR/$h"
  [ -e "$f" ] && act "remove hook $h" rm -f "$f"
done
# drop the pre/ dir only if now empty (never touch other user hooks)
if [ -d "$HOOKS_DIR" ] && [ -z "$(ls -A "$HOOKS_DIR" 2>/dev/null)" ]; then
  act "remove empty hooks/pre dir" rmdir "$HOOKS_DIR"
fi
[ -e "$HOOK_CFG" ] && act "remove attitude-gate.json" rm -f "$HOOK_CFG"

# 2) harness project override
[ -e "$HARNESS_CFG" ] && act "remove harness .gjc/config.yml" rm -f "$HARNESS_CFG"

# 3) global settings blocks (opt-in)
if [ "$SETTINGS" -eq 1 ] && [ -f "$GLOBAL_CFG" ]; then
  if [ "$DRY" -eq 1 ]; then
    say "  [dry-run] strip blocks from config.yml: ${REMOVE_BLOCKS[*]}"
  else
    cp -f "$GLOBAL_CFG" "$GLOBAL_CFG.revert-bak.$TS" && say "  [backup] $GLOBAL_CFG.revert-bak.$TS"
    strip_blocks "$GLOBAL_CFG" "${REMOVE_BLOCKS[@]}" && say "  [done] stripped blocks: ${REMOVE_BLOCKS[*]}"
  fi
fi

say "revert complete.$([ "$DRY" -eq 1 ] && printf ' (dry-run — nothing changed)')"
[ "$SETTINGS" -eq 0 ] && say "note: GJC compaction/memory settings kept. Re-run with --settings to remove them too."
