# oh-my-agent-env: GJC / OMO / Herdr install and portable configuration
# Sourced by lib/sync.sh; not standalone.
# shellcheck shell=bash

merge_agent_keybindings() {
  local target="$1" managed="$2"
  mkdir -p "$(dirname "$target")"
  python3 - "$target" "$managed" <<'PY'
import json, os, shutil, sys, tempfile
from pathlib import Path

target, managed = map(Path, sys.argv[1:3])
try:
    desired = json.loads(managed.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"[FAIL] invalid managed keybindings {managed}: {exc}")
    sys.exit(2)

if target.exists():
    try:
        current = json.loads(target.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[WARN] invalid JSON left unchanged: {target}: {exc}")
        sys.exit(3)
    if not isinstance(current, dict):
        print(f"[WARN] non-object JSON left unchanged: {target}")
        sys.exit(3)
else:
    current = {}

merged = dict(current)
merged.update(desired)
rendered = json.dumps(merged, ensure_ascii=False, indent=2) + "\n"
old = target.read_text(encoding="utf-8") if target.exists() else None
if old == rendered:
    print(f"[OK] {target} already current")
    sys.exit(0)
if target.exists():
    shutil.copy2(target, target.with_name(target.name + ".bak.oh-my-agent-env"))
fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"[OK] merged managed keybindings into {target}")
PY
}

merge_herdr_config() {
  local target="$1" managed="$2"
  mkdir -p "$(dirname "$target")"
  python3 - "$target" "$managed" <<'PY'
import os, re, shutil, sys, tempfile
from pathlib import Path

target, managed = map(Path, sys.argv[1:3])
template = managed.read_text(encoding="utf-8")
match = re.search(r'(?m)^prefix\s*=\s*("[^"]+")\s*$', template)
if not match:
    print(f"[FAIL] no valid prefix in {managed}")
    sys.exit(2)
prefix = f"prefix = {match.group(1)}"
old = target.read_text(encoding="utf-8") if target.exists() else ""
lines = old.splitlines()
headers = [i for i, line in enumerate(lines) if line.strip() == "[keys]"]
if len(headers) > 1:
    print(f"[WARN] duplicate [keys] sections left unchanged: {target}")
    sys.exit(3)
if headers:
    start = headers[0]
    end = next((i for i in range(start + 1, len(lines))
                if re.match(r"^\s*\[[^\]]+\]\s*$", lines[i])), len(lines))
    indexes = [i for i in range(start + 1, end) if re.match(r"^\s*prefix\s*=", lines[i])]
    if len(indexes) > 1:
        print(f"[WARN] duplicate keys.prefix entries left unchanged: {target}")
        sys.exit(3)
    if indexes:
        lines[indexes[0]] = prefix
    else:
        lines.insert(start + 1, prefix)
else:
    if lines and lines[-1].strip():
        lines.append("")
    lines.extend(template.rstrip().splitlines())
rendered = "\n".join(lines).rstrip() + "\n"
if old == rendered:
    print(f"[OK] {target} already current")
    sys.exit(0)
if target.exists():
    shutil.copy2(target, target.with_name(target.name + ".bak.oh-my-agent-env"))
fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"[OK] set Herdr prefix in {target}")
PY
}

merge_bash_aliases() {
  local target="$1"
  python3 - "$target" <<'PY'
import os, re, shutil, sys, tempfile
from pathlib import Path

target = Path(sys.argv[1])
target.parent.mkdir(parents=True, exist_ok=True)
begin = "# >>> oh-my-agent-env:herdr-agents >>>"
end = "# <<< oh-my-agent-env:herdr-agents <<<"
block = """# >>> oh-my-agent-env:herdr-agents >>>
# Herdr-aware wrappers are vanilla-equivalent outside Herdr.
if [ -x "$HOME/.local/bin/gjc-herdr" ]; then alias gjc='gjc-herdr'; fi
if [ -x "$HOME/.local/bin/omo-herdr" ]; then alias omo='omo-herdr'; fi
# <<< oh-my-agent-env:herdr-agents <<<"""
old = target.read_text(encoding="utf-8") if target.exists() else ""
if (begin in old) != (end in old):
    print(f"[WARN] broken Herdr alias managed block left unchanged: {target}")
    sys.exit(3)
# Migrate the one-off block used before this became repository-managed.
base = re.sub(
    r"\n?# >>> Herdr agent recognition \(added [^)]+\) >>>.*?"
    r"# <<< Herdr agent recognition \(added [^)]+\) <<<\n?",
    "\n", old, flags=re.S)
if begin in base:
    head, rest = base.split(begin, 1)
    _, tail = rest.split(end, 1)
    rendered = head.rstrip() + "\n\n" + block + tail
else:
    rendered = base.rstrip() + ("\n\n" if base.strip() else "") + block + "\n"
rendered = rendered.rstrip() + "\n"
if old == rendered:
    print(f"[OK] {target} aliases already current")
    sys.exit(0)
if target.exists():
    shutil.copy2(target, target.with_name(target.name + ".bak.oh-my-agent-env"))
fd, tmp = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"[OK] installed Herdr aliases in {target}")
PY
}

sync_gjc_default_profile() {
  local profile
  profile="$(tr -d '[:space:]' < "$SCRIPT_DIR/runtimes/gjc/default-profile")"
  if command -v gjc >/dev/null 2>&1; then
    if gjc config set modelProfile.default "$profile" </dev/null >/dev/null 2>&1; then
      log_and_print "    [OK] GJC default profile: $profile"
    else
      log_and_print "    [WARN] GJC installed but default profile could not be set"
      WARNINGS=$((WARNINGS+1))
    fi
  else
    log_and_print "    [SKIP] GJC profile — gjc not installed yet"
  fi
}

sync_agent_cli_configs() {
  local gjc_dir="${GJC_CODING_AGENT_DIR:-$HOME/.gjc/agent}"
  local omo_dir="${OMO_CODING_AGENT_DIR:-$HOME/.omo/agent}"
  local herdr_dir="${HERDR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr}"
  local rc
  echo "[6b] GJC / OMO / Herdr portable configuration"

  rc=0; merge_agent_keybindings "$gjc_dir/keybindings.json" "$SCRIPT_DIR/runtimes/gjc/keybindings.json" || rc=$?
  [ "$rc" -eq 0 ] || { log_and_print "    [FAIL] GJC keybindings merge (rc=$rc)"; ERRORS=$((ERRORS+1)); }
  rc=0; merge_agent_keybindings "$omo_dir/keybindings.json" "$SCRIPT_DIR/runtimes/omo/keybindings.json" || rc=$?
  [ "$rc" -eq 0 ] || { log_and_print "    [FAIL] OMO keybindings merge (rc=$rc)"; ERRORS=$((ERRORS+1)); }
  rc=0; merge_herdr_config "$herdr_dir/config.toml" "$SCRIPT_DIR/runtimes/herdr/config.toml" || rc=$?
  [ "$rc" -eq 0 ] || { log_and_print "    [FAIL] Herdr config merge (rc=$rc)"; ERRORS=$((ERRORS+1)); }

  mkdir -p "$HOME/.local/bin"
  make_link "$SCRIPT_DIR/runtimes/herdr/gjc-herdr" "$HOME/.local/bin/gjc-herdr"
  make_link "$SCRIPT_DIR/runtimes/herdr/omo-herdr" "$HOME/.local/bin/omo-herdr"
  merge_bash_aliases "$HOME/.bashrc" || { log_and_print "    [FAIL] Bash alias merge"; ERRORS=$((ERRORS+1)); }
  sync_gjc_default_profile

  if command -v herdr >/dev/null 2>&1; then
    herdr config check >/dev/null 2>&1 || { log_and_print "    [WARN] Herdr rejected managed config"; WARNINGS=$((WARNINGS+1)); }
    [ "${HERDR_ENV:-}" = "1" ] || herdr server reload-config >/dev/null 2>&1 || true
  fi
}

sync_agent_cli_install() {
  echo "[6c] GJC / OMO / Herdr installation"
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:$USER_NPM_PREFIX/bin:$PATH"

  if command -v herdr >/dev/null 2>&1; then
    log_and_print "    [OK] Herdr installed -> $(command -v herdr)"
  elif command -v curl >/dev/null 2>&1; then
    log_and_print "    Installing Herdr from herdr.dev..."
    run_with_timeout "Herdr install" "curl -fsSL https://herdr.dev/install.sh | sh" | tail -3 || true
    command -v herdr >/dev/null 2>&1 \
      && log_and_print "    [OK] Herdr installed -> $(command -v herdr)" \
      || { log_and_print "    [WARN] Herdr install failed"; WARNINGS=$((WARNINGS+1)); }
  else
    log_and_print "    [SKIP] Herdr — curl not found"
    WARNINGS=$((WARNINGS+1))
  fi

  if command -v omo >/dev/null 2>&1; then
    log_and_print "    [OK] OMO installed -> $(command -v omo)"
  else
    log_and_print "    Installing OMO (npm package omo-ai)..."
    run_with_timeout "OMO install" "$NPM_USER_ENV npm install -g omo-ai < /dev/null" | tail -3 || true
    command -v omo >/dev/null 2>&1 \
      && log_and_print "    [OK] OMO installed -> $(command -v omo)" \
      || { log_and_print "    [WARN] OMO install failed"; WARNINGS=$((WARNINGS+1)); }
  fi

  if ! command -v bun >/dev/null 2>&1; then
    if command -v curl >/dev/null 2>&1; then
      log_and_print "    Installing Bun (required by GJC)..."
      run_with_timeout "Bun install" "curl -fsSL https://bun.sh/install | bash" | tail -3 || true
      export PATH="$HOME/.bun/bin:$PATH"
    else
      log_and_print "    [SKIP] Bun/GJC — curl not found"
    fi
  fi
  if command -v gjc >/dev/null 2>&1; then
    log_and_print "    [OK] GJC installed -> $(command -v gjc)"
  elif command -v bun >/dev/null 2>&1; then
    log_and_print "    Installing GJC (bun install -g gajae-code)..."
    run_with_timeout "GJC install" "bun install -g gajae-code < /dev/null" | tail -3 || true
    command -v gjc >/dev/null 2>&1 \
      && log_and_print "    [OK] GJC installed -> $(command -v gjc)" \
      || { log_and_print "    [WARN] GJC install failed"; WARNINGS=$((WARNINGS+1)); }
  else
    log_and_print "    [WARN] GJC unavailable because Bun is not installed"
    WARNINGS=$((WARNINGS+1))
  fi

  # First sync on a fresh machine reaches this only after GJC was installed.
  sync_gjc_default_profile
}
