#!/usr/bin/env python3
"""
Phase 2.7 — Function call chain extractor.

Builds caller/callee tables for the top-N hottest functions in the repo.

Sources:
  - graphify graph.json (relations: calls, method)
  - L1.json symbols (line numbers, file paths)

Output:
  .claude/codebase-scan/dataflow/call_chain.json   structured
  .claude/codebase-scan/dataflow/call_chain.md     human-readable
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path


def _label(node: dict) -> str:
    return node.get("label") or node.get("id") or "?"


def _loc(node: dict) -> str:
    sf = node.get("source_file") or ""
    sl = node.get("source_location") or ""
    return f"{sf}:{sl[1:]}" if sl.startswith("L") and sl[1:].isdigit() else (sf or "?")


def build_chains(g: dict, top_n: int, hops: int) -> dict:
    nodes = g["nodes"]
    links = g.get("links") or []
    nodes_by_id = {n["id"]: n for n in nodes}

    call_links = [l for l in links if l.get("relation") in ("calls", "method")]

    # adjacency
    callers_of: dict[str, set[str]] = defaultdict(set)  # callee -> {callers}
    callees_of: dict[str, set[str]] = defaultdict(set)  # caller -> {callees}
    for l in call_links:
        s, t = l.get("source"), l.get("target")
        if not s or not t:
            continue
        callees_of[s].add(t)
        callers_of[t].add(s)

    # rank by inbound call count (heavy callees)
    inbound_count = Counter({k: len(v) for k, v in callers_of.items()})
    # only keep function-like nodes (exclude L1 file nodes)
    function_ids = [
        nid for nid in inbound_count
        if nid in nodes_by_id and nodes_by_id[nid].get("source_location") != "L1"
    ]
    function_ids.sort(key=lambda k: -inbound_count[k])

    chains: list[dict] = []
    for nid in function_ids[:top_n]:
        if nid not in nodes_by_id:
            continue
        anchor = nodes_by_id[nid]
        # callers (hop 1)
        h1_callers = sorted(callers_of.get(nid, set()))
        # callees (hop 1)
        h1_callees = sorted(callees_of.get(nid, set()))
        chains.append({
            "anchor": _label(anchor),
            "anchor_loc": _loc(anchor),
            "inbound_calls": inbound_count[nid],
            "outbound_calls": len(h1_callees),
            "callers": [
                {"label": _label(nodes_by_id.get(c, {"label": c})),
                 "loc": _loc(nodes_by_id.get(c, {}))}
                for c in h1_callers[:15]
            ],
            "callees": [
                {"label": _label(nodes_by_id.get(c, {"label": c})),
                 "loc": _loc(nodes_by_id.get(c, {}))}
                for c in h1_callees[:15]
            ],
        })
    return {"chains": chains, "n_call_links": len(call_links)}


def render_md(result: dict) -> str:
    md = ["# Function Call Chain (top callees + their callers/callees)", ""]
    md.append(f"_Built from graphify `calls`+`method` edges ({result['n_call_links']} total)._")
    md.append("")
    for c in result["chains"]:
        md.append(f"## `{c['anchor']}`  ({c['anchor_loc']})")
        md.append(f"- inbound: **{c['inbound_calls']}** callers  ·  outbound: **{c['outbound_calls']}** callees")
        if c["callers"]:
            md.append("- **Callers** (who calls this):")
            for v in c["callers"]:
                md.append(f"  - `{v['label']}`  ({v['loc']})")
        if c["callees"]:
            md.append("- **Callees** (what this calls):")
            for v in c["callees"]:
                md.append(f"  - `{v['label']}`  ({v['loc']})")
        md.append("")
    return "\n".join(md)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("repo", type=Path)
    p.add_argument("--graphify", type=Path, default=None)
    p.add_argument("--out", type=Path, default=None)
    p.add_argument("--top", type=int, default=20)
    p.add_argument("--hops", type=int, default=1, choices=(1, 2))
    args = p.parse_args()

    repo = args.repo.resolve()
    graph_path = args.graphify or (repo / "graphify-out" / "graph.json")
    out_dir = args.out or (repo / ".claude" / "codebase-scan" / "dataflow")

    try:
        g = json.loads(graph_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"[err] graphify graph not loaded: {e}", file=sys.stderr)
        return 2

    result = build_chains(g, top_n=args.top, hops=args.hops)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "call_chain.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    (out_dir / "call_chain.md").write_text(render_md(result))
    print(f"[ok] wrote call chain for {len(result['chains'])} anchors → {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
