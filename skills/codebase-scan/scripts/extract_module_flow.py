#!/usr/bin/env python3
"""
Phase 2.6 — Per-module code flow extractor.

Groups graphify nodes by (a) directory (SRP-aligned modules) and (b) community
(graph-clustered modules), then summarizes for each group:
  - internal nodes (files / functions / classes)
  - internal call/contains/method/inherits edges
  - outbound public-API edges (intra-repo, target outside module)
  - inbound dependents (source outside module, target inside)

Output: <repo>/.claude/codebase-scan/modules/{dir|community}/<slug>.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


# Canonical top-level dirs always emitted as their own bucket, regardless of
# the detected layout. Anything else is bucketed by the auto-detected layout.
TOPLEVEL_KEEP = {"scripts", "tests", "test", "examples", "benchmarks", "docs"}


def _slug(s: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]+", "-", s).strip("-")


def detect_layout(nodes: list[dict]) -> tuple[set[str], set[str]]:
    """Auto-detect module layout from observed source files.

    Returns (src_packages, flat_top_dirs):
      src_packages   = {"src/<pkg>", ...} for src-layout repos
      flat_top_dirs  = {"<top>", ...}     for flat-layout repos
    Both can be non-empty (mixed layout, e.g. src/pkg + top-level model/).
    """
    src_pkgs: set[str] = set()
    flat_top: set[str] = set()
    for n in nodes:
        sf = (n.get("source_file") or "").replace("\\", "/")
        if not sf or not sf.endswith(".py"):
            continue
        parts = sf.split("/")
        if parts[0] == "src" and len(parts) >= 3:
            src_pkgs.add(f"src/{parts[1]}")
        elif len(parts) >= 2:
            flat_top.add(parts[0])
    return src_pkgs, flat_top


def directory_of(
    source_file: str | None,
    src_pkgs: set[str],
    flat_top: set[str],
) -> str | None:
    """Map a file path to its module bucket given the detected layout."""
    if not source_file:
        return None
    sf = source_file.replace("\\", "/")
    parts = sf.split("/")
    if not parts:
        return None
    # 1) canonical top-level dirs win first
    if parts[0] in TOPLEVEL_KEEP:
        return parts[0]
    # 2) src-layout: src/<pkg>/<subdir>/...  →  "src/<pkg>/<subdir>"
    for pkg in src_pkgs:
        prefix = pkg + "/"
        if sf.startswith(prefix):
            pkg_depth = len(pkg.split("/"))
            if len(parts) > pkg_depth + 1:
                sub = parts[pkg_depth]
                if sub.endswith(".py"):
                    return f"{pkg}/_root"
                return f"{pkg}/{sub}"
            return f"{pkg}/_root"
    # 3) flat-layout: <top>/...
    if parts[0] in flat_top and len(parts) >= 2:
        return parts[0]
    return "other"


def group_by_directory(nodes: list[dict]) -> dict[str, list[dict]]:
    src_pkgs, flat_top = detect_layout(nodes)
    out: dict[str, list[dict]] = defaultdict(list)
    for n in nodes:
        d = directory_of(n.get("source_file"), src_pkgs, flat_top)
        if d is None:
            continue
        out[d].append(n)
    return out


def group_by_community(nodes: list[dict], min_size: int = 5) -> dict[str, list[dict]]:
    by_comm: dict[int, list[dict]] = defaultdict(list)
    for n in nodes:
        c = n.get("community")
        if c is not None:
            by_comm[c].append(n)
    return {f"C{c}": v for c, v in by_comm.items() if len(v) >= min_size}


def summarize_module(
    name: str,
    nodes: list[dict],
    links: list[dict],
    nodes_by_id: dict[str, dict],
) -> dict:
    member_ids = {n["id"] for n in nodes}
    files = sorted({n["source_file"] for n in nodes if n.get("source_file")})

    funcs = [
        {
            "id": n["id"],
            "label": n.get("label"),
            "source_file": n.get("source_file"),
            "source_location": n.get("source_location"),
        }
        for n in nodes
        if n.get("file_type") == "code" and n.get("source_location") != "L1"
    ]
    file_nodes = [n for n in nodes if n.get("source_location") == "L1"]

    rel_count: Counter = Counter()
    internal_edges: list[dict] = []
    outbound: list[dict] = []
    inbound: list[dict] = []
    for l in links:
        s, t, rel = l.get("source"), l.get("target"), l.get("relation")
        if not s or not t:
            continue
        in_s, in_t = s in member_ids, t in member_ids
        if in_s and in_t:
            internal_edges.append(l)
            rel_count[rel] += 1
        elif in_s and not in_t:
            outbound.append(l)
        elif in_t and not in_s:
            inbound.append(l)

    # Outbound / inbound, split by relation. Imports vs calls/method carry
    # different meaning (declared dependency vs actual runtime use), so we
    # surface them separately. `_uses` is a catch-all bucket.
    def _classify(rel: str) -> str:
        if not rel:
            return "uses"
        r = rel.lower()
        if r.startswith("import") or r == "imports_from":
            return "imports"
        if r in ("calls", "method"):
            return "calls"
        if r == "inherits":
            return "inherits"
        if r == "contains":
            return "contains"
        return "uses"

    def _split_by_rel(edges: list[dict], other_side: str) -> dict:
        per_rel: dict[str, dict[str, int]] = {
            k: defaultdict(int) for k in ("imports", "calls", "inherits", "contains", "uses")
        }
        per_rel_count: Counter = Counter()
        for l in edges:
            tgt = nodes_by_id.get(l.get(other_side))
            if not tgt:
                continue
            f = tgt.get("source_file") or "<unknown>"
            bucket = _classify(l.get("relation"))
            per_rel[bucket][f] += 1
            per_rel_count[bucket] += 1
        return {
            "by_relation_top_files": {
                k: sorted(v.items(), key=lambda kv: -kv[1])[:15]
                for k, v in per_rel.items() if v
            },
            "by_relation_counts": dict(per_rel_count),
        }

    out_split = _split_by_rel(outbound, "target")
    in_split = _split_by_rel(inbound, "source")

    # Back-compat: total top targets/sources (still relation-agnostic).
    out_by_file: dict[str, int] = defaultdict(int)
    for l in outbound:
        tgt = nodes_by_id.get(l.get("target"))
        if tgt:
            out_by_file[tgt.get("source_file") or "<unknown>"] += 1
    in_by_file: dict[str, int] = defaultdict(int)
    for l in inbound:
        src = nodes_by_id.get(l.get("source"))
        if src:
            in_by_file[src.get("source_file") or "<unknown>"] += 1

    return {
        "name": name,
        "n_files": len(files),
        "n_functions": len(funcs),
        "files": files,
        "functions": funcs[:200],
        "internal_edge_counts_by_relation": dict(rel_count),
        "n_internal_edges": len(internal_edges),
        "n_outbound_edges": len(outbound),
        "n_inbound_edges": len(inbound),
        "outbound_top_targets": sorted(out_by_file.items(), key=lambda kv: -kv[1])[:15],
        "inbound_top_sources": sorted(in_by_file.items(), key=lambda kv: -kv[1])[:15],
        "outbound_by_relation": out_split,
        "inbound_by_relation": in_split,
        "intra_call_edges": [
            {"src": l["source"], "tgt": l["target"], "relation": l["relation"]}
            for l in internal_edges
            if l.get("relation") in ("calls", "method", "contains")
        ][:300],
    }


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("repo", type=Path)
    p.add_argument("--graphify", type=Path, default=None,
                   help="graphify graph.json (default <repo>/graphify-out/graph.json)")
    p.add_argument("--out", type=Path, default=None,
                   help="output dir (default <repo>/.claude/codebase-scan/modules)")
    p.add_argument("--min-community-size", type=int, default=5)
    args = p.parse_args()

    repo = args.repo.resolve()
    graph_path = args.graphify or (repo / "graphify-out" / "graph.json")
    out_dir = args.out or (repo / ".claude" / "codebase-scan" / "modules")

    if not graph_path.exists():
        print(f"[err] graphify graph.json not found at {graph_path}", file=sys.stderr)
        return 2

    try:
        g = json.loads(graph_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        print(f"[err] failed to load graph: {e}", file=sys.stderr)
        return 2

    nodes = g["nodes"]
    links = g.get("links") or g.get("edges") or []
    nodes_by_id = {n["id"]: n for n in nodes}

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "dir").mkdir(exist_ok=True)
    (out_dir / "community").mkdir(exist_ok=True)

    summary_index: list[dict] = []

    dir_groups = group_by_directory(nodes)
    for mod_name, mod_nodes in sorted(dir_groups.items()):
        if not mod_nodes:
            continue
        s = summarize_module(mod_name, mod_nodes, links, nodes_by_id)
        slug = _slug(mod_name)
        (out_dir / "dir" / f"{slug}.json").write_text(
            json.dumps(s, indent=2, ensure_ascii=False)
        )
        summary_index.append({"kind": "dir", "name": mod_name, "slug": slug,
                              "n_files": s["n_files"], "n_internal_edges": s["n_internal_edges"]})

    comm_groups = group_by_community(nodes, min_size=args.min_community_size)
    for cname, cnodes in sorted(comm_groups.items()):
        s = summarize_module(cname, cnodes, links, nodes_by_id)
        slug = _slug(cname)
        (out_dir / "community" / f"{slug}.json").write_text(
            json.dumps(s, indent=2, ensure_ascii=False)
        )
        summary_index.append({"kind": "community", "name": cname, "slug": slug,
                              "n_files": s["n_files"], "n_internal_edges": s["n_internal_edges"]})

    (out_dir / "index.json").write_text(
        json.dumps({"modules": summary_index}, indent=2, ensure_ascii=False)
    )
    print(f"[ok] wrote {len(summary_index)} module summaries to {out_dir}")
    print(f"  - dir modules: {sum(1 for x in summary_index if x['kind']=='dir')}")
    print(f"  - community modules: {sum(1 for x in summary_index if x['kind']=='community')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
