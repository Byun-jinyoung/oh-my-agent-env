# oh-my-agent-env: sync domain - rules.sh
# Sourced by lib/sync.sh; not standalone.
# shellcheck shell=bash   # sourced fragment: no shebang by design

# [3][3b][4][4b] Codex flags, Gemini dir, retire the old global rules
#
# Global agent rules now belong to OMS (~/.oh-my-setting links CLAUDE.md and
# AGENTS.md to its rules/global-AGENTS.md). This repo keeps rules/*.md and
# assemble_global_rules for reference only and no longer writes them: an
# assembly over an OMS symlink would replace the link with a plain file.
sync_agent_rules() {
  echo "[3] Codex"
  mkdir -p "$CODEX_DIR"
  echo "[3b] Codex feature flags"
  ensure_codex_multi_agent

  echo "[4] Gemini"
  mkdir -p "$GEMINI_DIR"

  echo "[4b] Retire repo global rules (OMS owns them)"
  retire_global_rules || ERRORS=$(( ${ERRORS:-0} + 1 ))
}

# Remove what earlier syncs installed: the managed block in each CLI's global
# file and the ~/.codex/instructions.md link into this repo. Symlinks (OMS)
# and text outside the block are never touched; a file left empty is removed.
retire_global_rules() {
  local link="$CODEX_DIR/instructions.md" rc=0 f
  if [ -L "$link" ] && case "$(readlink "$link")" in "$SCRIPT_DIR"/*) true ;; *) false ;; esac; then
    rm -f "$link" && log_and_print "    [RETIRE] $link (link into this repo)"
  fi
  command -v python3 &>/dev/null || { log_and_print "    [SKIP] python3 missing — env blocks not retired"; return 1; }
  for f in "$CONFIG_DIR/CLAUDE.md" "$CODEX_DIR/AGENTS.md" "$GEMINI_DIR/GEMINI.md"; do
    python3 - "$f" "$OMA_BLOCK_BEGIN" "$OMA_BLOCK_END" <<'PYEOF' | sed 's/^/    /'
import os, sys, tempfile
from pathlib import Path

target, begin, end = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
if target.is_symlink() or not target.is_file():
    sys.exit(0)
old = target.read_text(encoding="utf-8")
if begin not in old and end not in old:
    sys.exit(0)
if old.count(begin) != 1 or old.count(end) != 1 or old.index(begin) > old.index(end):
    print(f"[WARN] {target}: malformed env block — left unchanged")
    sys.exit(3)
head, rest = old.split(begin, 1)
tail = rest.split(end, 1)[1]
new = (head.rstrip() + "\n\n" + tail.lstrip()).strip()
if not new:
    target.unlink()
    print(f"[RETIRE] {target} (held only the env block — removed)")
    sys.exit(0)
fd, tmp = tempfile.mkstemp(dir=str(target.parent), prefix=f".{target.name}.")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(new + "\n")
os.chmod(tmp, target.stat().st_mode & 0o777)
os.replace(tmp, target)
print(f"[RETIRE] {target} (env block removed, other text kept)")
PYEOF
    [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
  done
  return "$rc"
}
