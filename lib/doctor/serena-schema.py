#!/usr/bin/env python3
"""Ask the INSTALLED serena whether it can load each .serena/project.yml.

Run with serena's own interpreter (doctor resolves it from the `serena`
shebang), so `import serena` is the build that will actually handle the MCP
handshake — not whatever python happens to be first on PATH.

Why not grep the YAML: doctor used to, and it could not tell "key absent" from
"key present but empty". 13 configs on this machine carried `language_servers:`
written by a different build; the release needs `languages:`, raised KeyError
before the handshake, and surfaced as a connection failure with no reason —
while doctor printed "[OK] carries every key". Loading through the real loader
and comparing against the real FIELDS_WITHOUT_DEFAULTS cannot drift from what
serena demands, including when upstream renames the key again.

Verdicts, one line per config:
  [OK]    loader is satisfied
  [MISS]  a required key is absent — serena dies before the handshake
  [NOTE]  loads, but `languages` is empty: symbol tools return nothing. Not an
          error (a repo with no source files is legitimately empty), so it does
          not raise doctor's warning count; it is said out loud because an empty
          list is indistinguishable from a working setup from the outside.
  [WARN]  the file could not be read or parsed at all

With --fix, a [MISS] is repaired instead of merely reported: the key holding the
language list is renamed to whatever the installed loader asks for. Reporting
only was the first design and it was wrong — it left the operator hand-editing
one YAML per repo per machine, which is the opposite of the idempotent-config
rule this harness is built on.

Two properties make the repair safe to run anywhere:

  - the target key name is READ FROM THE LOADER, never hardcoded. Upstream has
    already renamed this field once and can rename it back; a fixer that knows
    the name would then rewrite every config in the wrong direction. This one
    rewrites toward whatever the installed build demands, so an upgrade that
    flips the name makes it repair in the other direction with no code change.
  - the edit is a line-level rename of the key token, not a YAML round-trip.
    These files carry ~10KB of comments; dumping them through a YAML emitter
    would silently delete all of it. Everything except the one key stays byte
    identical.

After writing, the file is handed back to the loader. If it does not load, the
backup is restored — a config that fails differently is not an improvement.
"""
import os
import shutil
import sys


def rename_key(path, old, new):
    """Rewrite `old:` to `new:` at the start of a line. Returns True if changed.

    Line-level on purpose: see the module docstring. Only a top-level mapping
    key is touched (column 0), so a nested key or a mention inside a comment or
    a string is left alone.
    """
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    hit = False
    for i, line in enumerate(lines):
        if line.startswith(old + ":"):
            lines[i] = new + ":" + line[len(old) + 1:]
            hit = True
    if not hit:
        return False
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    return True


def repair(path, repo, missing, other, loader):
    """Rename the language key and verify the result loads. Restores on failure."""
    if len(missing) != 1 or len(other) != 1:
        print("       [SKIP FIX] expected exactly one missing key and one candidate,"
              " got %d/%d — repairing this needs a human" % (len(missing), len(other)))
        return False
    backup = path + ".oma-bak"
    shutil.copy2(path, backup)
    if not rename_key(path, other[0], missing[0]):
        os.remove(backup)
        print("       [SKIP FIX] %s is not a top-level key in the file" % other[0])
        return False
    try:
        data, _ = loader(path)
        still = sorted(k for k in missing if k not in data)
    except Exception as exc:  # noqa: BLE001
        still, exc_msg = missing, str(exc)
    else:
        exc_msg = None
    if still:
        shutil.copy2(backup, path)
        os.remove(backup)
        print("       [FIX FAILED] %s still unloadable after rename (%s) — restored"
              % (repo, exc_msg or " ".join(still)))
        return False
    os.remove(backup)
    print("       [FIXED] renamed %s -> %s; loader is satisfied" % (other[0], missing[0]))
    return True


def registered_configs():
    """Every project serena itself will load, as .serena/project.yml paths.

    Doctor used to look at exactly two roots: this checkout and the current
    git repo. That is why a broken config in a research repo stayed invisible
    until someone happened to run doctor from inside it, and why repairing a
    machine meant visiting one repo at a time. serena's registry is the list of
    projects it will actually open, so it is the right denominator for "is this
    machine healthy" — and it makes the repair reachable from one place.

    Read here rather than in the shell caller because this process is serena's
    own interpreter, so yaml is guaranteed present.
    """
    path = os.path.expanduser("~/.serena/serena_config.yml")
    try:
        import yaml
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except Exception:  # noqa: BLE001 - no registry is not an error, just no extra roots
        return []
    out = []
    for root in data.get("projects") or []:
        cfg = os.path.join(str(root), ".serena", "project.yml")
        if os.path.isfile(cfg):
            out.append(cfg)
    return out


def main(argv):
    fix = "--fix" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if "--registered" in argv:
        paths = paths + registered_configs()
    try:
        from serena.config.serena_config import ProjectConfig
    except Exception as exc:  # noqa: BLE001 - any import failure is "cannot ask"
        print("[WARN] cannot import serena config module: %s" % exc)
        return 1

    required = set(ProjectConfig.FIELDS_WITHOUT_DEFAULTS)
    seen = set()
    for path in paths:
        try:
            st = os.stat(path)
        except OSError as exc:
            print("[WARN] %s unreadable: %s" % (path, exc))
            continue
        # The same worktree is visible under two paths on this machine; without
        # this the same file is reported twice as if it were two problems.
        key = (st.st_dev, st.st_ino)
        if key in seen:
            continue
        seen.add(key)

        repo = path[: -len("/.serena/project.yml")]
        try:
            data, _ = ProjectConfig._load_yaml_dict(path)
        except Exception as exc:  # noqa: BLE001
            print("[WARN] %s could not be parsed: %s" % (repo, exc))
            continue

        missing = sorted(k for k in required if k not in data)
        if missing:
            print("[MISS] %s lacks required key(s): %s" % (repo, " ".join(missing)))
            print("       serena raises KeyError before the MCP handshake, so it reports as")
            print("       a connection failure with no reason. Another build wrote this file.")
            # Name the likely culprit, but only a key that actually holds a
            # list of languages. `language_backend:` also matches on name and is
            # legitimately present and empty; pointing at it would send the
            # reader to rename a key that is not the problem.
            other = [k for k, v in data.items()
                     if k not in required and "lang" in k.lower()
                     and isinstance(v, list) and v]
            if other:
                print("       it carries %s instead — rename that key to %s"
                      % (" ".join(other), " ".join(missing)))
                if fix:
                    repair(path, repo, missing, other, ProjectConfig._load_yaml_dict)
            elif fix:
                print("       [SKIP FIX] no key holding a non-empty language list to rename")
            continue

        langs = data.get("languages") or []
        if not langs:
            print("[NOTE] %s loads, but languages is empty — symbol tools return nothing" % repo)
        else:
            print("[OK] %s loads; languages=%s" % (repo, " ".join(str(x) for x in langs)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
# Deliberately no --dry-run flag: the default IS the dry run. Running without
# --fix reports and changes nothing, which is the mode doctor uses.
