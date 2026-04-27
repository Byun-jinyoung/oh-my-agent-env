#!/usr/bin/env python3
"""Extract CRG SQLite graph into structured L1.json for codebase-scan skill.

Usage:
  extract_l1.py <repo_root>

Output: <repo_root>/.claude/codebase-scan/evidence/L1.json
"""
import json
import sqlite3
import sys
from pathlib import Path


def normalize(path: str, repo_root: Path) -> str:
    p = path
    for prefix in ("/private", ""):
        full = prefix + str(repo_root)
        if p.startswith(full + "/"):
            return p[len(full) + 1:]
    return p


def extract(repo_root: Path) -> dict:
    db = repo_root / ".code-review-graph" / "graph.db"
    if not db.exists():
        raise SystemExit(f"CRG graph not found at {db}. Run: code-review-graph build --repo {repo_root}")

    con = sqlite3.connect(db)
    con.row_factory = sqlite3.Row

    symbols: dict[str, list] = {}
    for r in con.execute(
        "SELECT file_path,kind,name,line_start,line_end,qualified_name FROM nodes "
        "WHERE kind IN ('Class','Function','Method','Test','Type') ORDER BY file_path,line_start"
    ):
        f = normalize(r["file_path"], repo_root)
        symbols.setdefault(f, []).append({
            "kind": r["kind"], "name": r["name"],
            "line_start": r["line_start"], "line_end": r["line_end"],
            "qualified": r["qualified_name"],
        })

    hubs = [dict(r) for r in con.execute(
        "SELECT target_qualified, COUNT(*) AS c FROM edges WHERE kind='CALLS' "
        "AND target_qualified LIKE '%::%' "
        "GROUP BY target_qualified ORDER BY c DESC LIMIT 30"
    )]

    blast = [dict(r) for r in con.execute(
        "SELECT file_path, COUNT(DISTINCT target_qualified) AS touched "
        "FROM edges GROUP BY file_path ORDER BY touched DESC LIMIT 15"
    )]
    for b in blast:
        b["file_path"] = normalize(b["file_path"], repo_root)

    inherits = [dict(r) for r in con.execute(
        "SELECT source_qualified, target_qualified FROM edges WHERE kind='INHERITS' ORDER BY target_qualified"
    )]

    edge_kinds = dict(con.execute("SELECT kind, COUNT(*) FROM edges GROUP BY kind"))
    node_kinds = dict(con.execute("SELECT kind, COUNT(*) FROM nodes GROUP BY kind"))

    con.close()
    return {
        "repo": str(repo_root),
        "node_kinds": node_kinds,
        "edge_kinds": edge_kinds,
        "symbols": symbols,
        "hubs": hubs,
        "blast": blast,
        "inherits": inherits,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    repo_root = Path(sys.argv[1]).resolve()
    if not repo_root.is_dir():
        print(f"Not a directory: {repo_root}", file=sys.stderr)
        return 2

    out_dir = repo_root / ".claude" / "codebase-scan" / "evidence"
    out_dir.mkdir(parents=True, exist_ok=True)

    data = extract(repo_root)
    out = out_dir / "L1.json"
    out.write_text(json.dumps(data, default=str))

    files = len(data["symbols"])
    nodes = sum(data["node_kinds"].values())
    edges = sum(data["edge_kinds"].values())
    print(f"L1 extracted: {files} files, {nodes} nodes, {edges} edges -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
