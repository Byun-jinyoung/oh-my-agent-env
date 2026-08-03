#!/usr/bin/env bash
# Install the pre-push gate into THIS checkout's .git/hooks.
#
#   scripts/install-hooks.sh              install (refuses to clobber)
#   scripts/install-hooks.sh --force      install, backing up a foreign hook
#   scripts/install-hooks.sh --uninstall  remove ours, leave a foreign one alone
#   scripts/install-hooks.sh --status     report what is installed
#
# Opt-in on purpose. `setup.sh sync` does NOT call this: sync runs unattended and
# across machines, and silently installing something that can block a push is not
# its business. Running this is a decision, so it is a command.
#
# .git/hooks is per-checkout and untracked, which is why this is an installer and
# not a tracked file: cloning the repo gets you the script, not the hook.
#
# Cost, measured on this machine: scripts/check.sh takes 22s across its 8 stages
# (static analysis included) and 11s with --lint-only. A push is infrequent
# enough to pay 22s for the same gate CI runs, so the hook runs the full thing.
set -uo pipefail

MARKER="# oh-my-agent-env:pre-push"

die() { printf 'install-hooks: %s\n' "$*" >&2; exit 1; }

# --absolute-git-dir, not --git-dir: the plain form answers ".git" relative to the
# caller's cwd, so running this from a subdirectory would install into a path
# that does not exist. The hook resolves the worktree root itself at run time.
GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || die "not a git checkout"

# A repo with core.hooksPath set is not using .git/hooks, and writing there would
# install a hook that never runs — the quietest possible failure for a gate.
CUSTOM="$(git config core.hooksPath 2>/dev/null || true)"
if [ -n "$CUSTOM" ]; then
  die "core.hooksPath is set to '$CUSTOM'; this repo does not read .git/hooks. Install there yourself or unset it."
fi

HOOK_DIR="$GITDIR/hooks"
HOOK="$HOOK_DIR/pre-push"

is_ours() { [ -f "$1" ] && grep -qF "$MARKER" "$1"; }

write_hook() {
  mkdir -p "$HOOK_DIR" || die "cannot create $HOOK_DIR"
  cat > "$HOOK" <<'HOOKEOF'
#!/usr/bin/env bash
# oh-my-agent-env:pre-push
# Runs the same gate CI runs before anything leaves this machine.
# Skip once:  git push --no-verify
# Skip always: OMA_SKIP_PREPUSH=1 in your environment
# Remove: scripts/install-hooks.sh --uninstall
set -uo pipefail

if [ "${OMA_SKIP_PREPUSH:-0}" = "1" ]; then
  echo "pre-push: skipped (OMA_SKIP_PREPUSH=1)"
  exit 0
fi

root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
gate="$root/scripts/check.sh"

# Fail closed. A gate that waves the push through because its own script went
# missing is worse than no gate: it reports the same success as a clean run.
if [ ! -f "$gate" ]; then
  echo "pre-push: $gate is missing — refusing to push unchecked." >&2
  echo "          Re-run scripts/install-hooks.sh --uninstall if this is intended." >&2
  exit 1
fi

echo "pre-push: running scripts/check.sh (~22s; --no-verify to skip)"
bash "$gate"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "pre-push: check.sh failed (rc=$rc) — push aborted." >&2
fi
exit "$rc"
HOOKEOF
  chmod +x "$HOOK" || die "cannot chmod $HOOK"
}

cmd_status() {
  if [ ! -e "$HOOK" ]; then
    echo "pre-push: not installed"
  elif is_ours "$HOOK"; then
    echo "pre-push: installed (oh-my-agent-env) -> $HOOK"
  else
    echo "pre-push: present but NOT ours -> $HOOK"
  fi
}

cmd_install() {
  local force="$1"
  if is_ours "$HOOK"; then
    write_hook   # refresh in place: idempotent, and picks up changes to this file
    echo "pre-push: up to date -> $HOOK"
    return 0
  fi
  if [ -e "$HOOK" ]; then
    if [ "$force" != "1" ]; then
      die "$HOOK already exists and was not written by this script. Re-run with --force to back it up and replace it."
    fi
    local backup="$HOOK.pre-oma"
    # Never overwrite a previous backup — that would destroy the original the
    # first --force preserved.
    local n=1
    while [ -e "$backup" ]; do backup="$HOOK.pre-oma.$n"; n=$((n + 1)); done
    mv "$HOOK" "$backup" || die "cannot back up $HOOK"
    echo "pre-push: existing hook moved to $backup"
  fi
  write_hook
  echo "pre-push: installed -> $HOOK"
  echo "          runs scripts/check.sh; skip once with 'git push --no-verify'"
}

cmd_uninstall() {
  if [ ! -e "$HOOK" ]; then
    echo "pre-push: nothing to remove"
    return 0
  fi
  if ! is_ours "$HOOK"; then
    die "$HOOK was not written by this script — leaving it alone"
  fi
  rm -f "$HOOK" || die "cannot remove $HOOK"
  echo "pre-push: removed $HOOK"
}

FORCE=0
ACTION=install
while [ $# -gt 0 ]; do
  case "$1" in
    --force)     FORCE=1 ;;
    --uninstall) ACTION=uninstall ;;
    --status)    ACTION=status ;;
    -h|--help)   sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
  shift
done

case "$ACTION" in
  install)   cmd_install "$FORCE" ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
esac
