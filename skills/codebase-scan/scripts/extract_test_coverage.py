#!/usr/bin/env python3
"""
Phase 2.8 — Test coverage map from CRG TESTED_BY edges.

Reads `<repo>/.code-review-graph/graph.db`, table `edges`, kind='TESTED_BY'.
Schema:
  source_qualified : production symbol (e.g., `AtomEncoder`,
                     or `/abs/path/file.py::func`)
  target_qualified : test function (always `/abs/path/tests/...::test_*`)

Emits:
  .claude/codebase-scan/coverage/coverage_map.json
  .claude/codebase-scan/coverage/coverage_map.md

Sections in markdown:
  A. Most-tested production symbols (top 30)
  B. Highest-coverage tests (top 20)
  C. Untested top-blast files (cross-ref with L1 blast)
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path


def _strip_repo(qual: str, repo: Path) -> str:
    """Remove leading absolute repo path; keep `file.py::sym` or bare symbol."""
    s = str(repo)
    if qual.startswith(s + "/"):
        return qual[len(s) + 1:]
    return qual


def load_tested_by(db_path: Path, repo: Path) -> list[dict]:
    if not db_path.exists():
        raise FileNotFoundError(f"CRG db not found: {db_path}")
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        "SELECT source_qualified, target_qualified, file_path, line "
        "FROM edges WHERE kind='TESTED_BY'"
    ).fetchall()
    con.close()
    out = []
    for r in rows:
        out.append({
            "production": _strip_repo(r["source_qualified"], repo),
            "test": _strip_repo(r["target_qualified"], repo),
            "file": _strip_repo(r["file_path"] or "", repo),
            "line": r["line"],
        })
    return out


def load_known_symbols(repo: Path) -> tuple[set[str], dict[str, set[str]]]:
    """Load Class/Function symbol set + name→files lookup from L1.json.

    Returns (production_name_set, name_to_files). `name_to_files[name]` lists
    every file that defines a symbol of that name — used to attribute bare
    names back to a file when computing untested-blast.
    `production_name_set` excludes symbols defined inside `tests/...` so a
    bare `_make_ctx` doesn't get rescued by a test helper of the same name.
    """
    l1 = repo / ".claude" / "codebase-scan" / "evidence" / "L1.json"
    if not l1.exists():
        return set(), {}
    try:
        data = json.loads(l1.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return set(), {}

    prod_names: set[str] = set()
    name_to_files: dict[str, set[str]] = defaultdict(set)
    for file_path, file_syms in (data.get("symbols") or {}).items():
        # store both production-name set and name→files index
        is_test = "tests/" in file_path.replace("\\", "/") or file_path.endswith(("_test.py",))
        for s in file_syms:
            n = s.get("name")
            if not n:
                continue
            name_to_files[n].add(file_path)
            if not is_test:
                prod_names.add(n)
    return prod_names, {k: v for k, v in name_to_files.items()}


def _is_test_path_qual(prod: str) -> bool:
    """True if a `file::sym` qualified path lives under tests/."""
    if "::" not in prod:
        return False
    file_part = prod.split("::", 1)[0].replace("\\", "/")
    return file_part.startswith("tests/") or "/tests/" in file_part


def filter_edges(
    edges: list[dict], prod_names: set[str]
) -> tuple[list[dict], list[dict], int]:
    """Split into (production, external) by source symbol shape.

    Production = symbol defined in non-test repo code. Excludes:
      - bare names not in `prod_names` (stdlib/torch refs)
      - `tests/...::sym` qualified paths (test helpers)
    Returns (in_proj, external, n_test_helpers_filtered).
    """
    in_proj, ext = [], []
    n_test_helpers = 0
    for e in edges:
        prod = e["production"]
        if _is_test_path_qual(prod):
            ext.append(e)
            n_test_helpers += 1
            continue
        if "::" in prod:
            # qualified non-tests path → trust as in-project source
            in_proj.append(e)
        elif prod in prod_names:
            in_proj.append(e)
        else:
            ext.append(e)
    return in_proj, ext, n_test_helpers


def build_maps(edges: list[dict]) -> dict:
    prod_to_tests: dict[str, set[str]] = defaultdict(set)
    test_to_prods: dict[str, set[str]] = defaultdict(set)
    for e in edges:
        prod_to_tests[e["production"]].add(e["test"])
        test_to_prods[e["test"]].add(e["production"])

    most_tested = sorted(
        ((p, sorted(t)) for p, t in prod_to_tests.items()),
        key=lambda kv: -len(kv[1]),
    )
    highest_coverage = sorted(
        ((t, sorted(p)) for t, p in test_to_prods.items()),
        key=lambda kv: -len(kv[1]),
    )
    return {
        "n_edges": len(edges),
        "n_production_symbols": len(prod_to_tests),
        "n_test_functions": len(test_to_prods),
        "most_tested": most_tested,
        "highest_coverage": highest_coverage,
    }


def find_untested_blast(repo: Path, prod_files_tested: set[str]) -> tuple[list[dict], int, int]:
    """Cross-reference with L1 blast list to surface high-impact files with no tests.

    Excludes anything under tests/. Returns (untested, n_production_in_window, window_size).
    """
    l1 = repo / ".claude" / "codebase-scan" / "evidence" / "L1.json"
    if not l1.exists():
        return [], 0, 0
    try:
        data = json.loads(l1.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return [], 0, 0
    blast = data.get("blast") or []
    window = blast[:30]
    out: list[dict] = []
    n_prod = 0
    for item in window:
        if not isinstance(item, dict):
            continue
        f = item.get("file_path") or item.get("file")
        if not f:
            continue
        fn = f.replace("\\", "/")
        if fn.startswith("tests/") or "/tests/" in fn:
            continue
        n_prod += 1
        if f not in prod_files_tested:
            out.append({"file": f, "touched": item.get("touched", "?")})
    return out, n_prod, len(window)


def _production_file_set(
    maps: dict, name_to_files: dict[str, set[str]]
) -> tuple[set[str], list[str]]:
    """Files reached from production side of TESTED_BY.

    Two paths:
      - `file.py::sym` → take file directly (unambiguous).
      - bare `Sym` → look up `name_to_files[Sym]`. If the symbol is defined
        in exactly one non-test file, accept that file. If multiple files
        define a symbol with the same name, mark ambiguous and skip (avoids
        the false-positive identified by codex round-2 review — e.g., `main`
        defined in both scripts and tests).
    """
    files: set[str] = set()
    ambiguous: list[str] = []
    for prod, _ in maps["most_tested"]:
        if "::" in prod:
            f = prod.split("::", 1)[0]
            if f.endswith(".py"):
                files.add(f)
            continue
        candidates: set[str] = set()
        for f in name_to_files.get(prod, set()):
            fn = f.replace("\\", "/")
            if fn.startswith("tests/") or "/tests/" in fn:
                continue
            if "/PROject/" in f:
                f = f.split("/PROject/", 1)[1]
                f = f.split("/", 1)[1] if "/" in f else f
            candidates.add(f)
        if len(candidates) == 1:
            files.update(candidates)
        elif len(candidates) > 1:
            ambiguous.append(prod)
    return files, ambiguous


def render_md(
    maps: dict,
    untested_blast: list[dict],
    n_prod_in_window: int,
    window_size: int,
    ambiguous: list[str],
    top_p: int,
    top_t: int,
) -> str:
    out = ["# Test Coverage Map", ""]
    out.append(
        f"_From CRG TESTED_BY edges. {maps['n_edges']} edges · "
        f"{maps['n_production_symbols']} production symbols tested · "
        f"{maps['n_test_functions']} test functions._"
    )
    out.append("")

    out.append(f"## A. Most-tested production symbols (top {top_p})")
    out.append("")
    out.append("| Production symbol | # tests | First test |")
    out.append("|---|---:|---|")
    for prod, tests in maps["most_tested"][:top_p]:
        first = tests[0] if tests else "—"
        out.append(f"| `{prod}` | {len(tests)} | `{first}` |")
    out.append("")

    out.append(f"## B. Highest-coverage tests (top {top_t})")
    out.append("")
    out.append("| Test | # production symbols covered |")
    out.append("|---|---:|")
    for test, prods in maps["highest_coverage"][:top_t]:
        out.append(f"| `{test}` | {len(prods)} |")
    out.append("")

    if untested_blast:
        out.append("## C. ⚠️  High-blast production files with no TESTED_BY edges")
        out.append("")
        out.append(
            f"_From blast top-{window_size}, {n_prod_in_window} are production files "
            f"(non-test); the following lack TESTED_BY coverage._"
        )
        out.append("")
        out.append("| File | Blast (touched symbols) |")
        out.append("|---|---:|")
        for r in untested_blast:
            out.append(f"| `{r['file']}` | {r['touched']} |")
        out.append("")
    else:
        out.append("## C. High-blast coverage")
        out.append("")
        out.append(
            f"_All {n_prod_in_window} production files in blast top-{window_size} "
            f"have at least one TESTED_BY edge._"
        )

    if ambiguous:
        out.append("")
        out.append("## D. Ambiguous bare-name production symbols")
        out.append("")
        out.append(
            "_These names are defined in multiple production files; their TESTED_BY "
            "edges cannot be attributed to a single source file. Excluded from the "
            "blast-coverage check above._"
        )
        out.append("")
        for n in ambiguous[:20]:
            out.append(f"- `{n}`")

    return "\n".join(out)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("repo", type=Path)
    p.add_argument("--db", type=Path, default=None,
                   help="CRG sqlite path (default <repo>/.code-review-graph/graph.db)")
    p.add_argument("--out", type=Path, default=None,
                   help="output dir (default <repo>/.claude/codebase-scan/coverage)")
    p.add_argument("--top-production", type=int, default=30)
    p.add_argument("--top-tests", type=int, default=20)
    args = p.parse_args()

    repo = args.repo.resolve()
    db_path = args.db or (repo / ".code-review-graph" / "graph.db")
    out_dir = args.out or (repo / ".claude" / "codebase-scan" / "coverage")

    try:
        edges = load_tested_by(db_path, repo)
    except (FileNotFoundError, sqlite3.Error) as e:
        print(f"[err] cannot read TESTED_BY edges: {e}", file=sys.stderr)
        return 2

    prod_names, name_to_files = load_known_symbols(repo)
    in_proj_edges, external_edges, n_test_helpers = filter_edges(edges, prod_names)

    maps = build_maps(in_proj_edges)
    prod_files_tested, ambiguous = _production_file_set(maps, name_to_files)
    untested_blast, n_prod_in_window, window_size = find_untested_blast(repo, prod_files_tested)
    contamination_rate = (
        n_test_helpers / len(edges) if edges else 0.0
    )

    out_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        **maps,
        "untested_blast_files": untested_blast,
        "n_production_in_blast_window": n_prod_in_window,
        "blast_window_size": window_size,
        "ambiguous_bare_names": ambiguous,
        "filtered_external_edges": len(external_edges),
        "filtered_test_helpers": n_test_helpers,
        "test_helper_contamination_rate": round(contamination_rate, 4),
        "known_production_names": len(prod_names),
    }
    (out_dir / "coverage_map.json").write_text(
        json.dumps(payload, indent=2, ensure_ascii=False)
    )
    md = render_md(
        maps,
        untested_blast,
        n_prod_in_window,
        window_size,
        ambiguous,
        args.top_production,
        args.top_tests,
    )
    md += (
        f"\n\n## Filter stats\n\n"
        f"- Total raw TESTED_BY edges: **{len(edges)}**\n"
        f"- In-project edges: **{len(in_proj_edges)}**\n"
        f"- Test-helper edges filtered (source under `tests/`): **{n_test_helpers}**\n"
        f"- External edges (stdlib/torch/pytest references): "
        f"**{len(external_edges) - n_test_helpers}**\n"
        f"- Test-helper contamination rate: **{contamination_rate:.1%}**\n"
        f"- L1.json known production-name set size: **{len(prod_names)}**\n"
    )
    (out_dir / "coverage_map.md").write_text(md)

    print(
        f"[ok] coverage: {maps['n_edges']} in-project edges "
        f"(filtered {len(external_edges)} external, "
        f"{n_test_helpers} test-helpers) · "
        f"{maps['n_production_symbols']} prod · {maps['n_test_functions']} tests → {out_dir}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
