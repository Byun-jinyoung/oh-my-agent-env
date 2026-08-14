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
"""
import os
import sys


def main(paths):
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
            continue

        langs = data.get("languages") or []
        if not langs:
            print("[NOTE] %s loads, but languages is empty — symbol tools return nothing" % repo)
        else:
            print("[OK] %s loads; languages=%s" % (repo, " ".join(str(x) for x in langs)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
