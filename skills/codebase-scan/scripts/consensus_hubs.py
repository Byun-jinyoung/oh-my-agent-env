#!/usr/bin/env python3
"""
Phase 4.5 — Multi-tool consensus on hub files.

Inputs (each optional but ≥2 required):
  --crg-l1 <path>    L1.json (or L1-evidence.json) from code-review-graph (alias: --crg, deprecated)
  --graphify <path>  graph.json from graphify (graphify-out/graph.json)
  --codex <path>     JSON file with codex-mcp response: {"hubs":[{"file":..,"rank":..}, ...]}
  --antigravity <path>  JSON file with antigravity-mcp response (same schema)
  --serena <path>    optional serena symbols file (used as weak tiebreaker)

Outputs:
  <out>/hubs-consensus.md       table with vote counts and labels
  <out>/disagreements.md        DEBATE items + explanations
  <out>/hubs-consensus.json     machine-readable

Labels per file:
  CONSENSUS  — appears in top-K of ≥3 sources
  MAJORITY   — top-K of exactly 2 sources
  SINGLE     — top-K of 1 source
  DEBATE     — only one source places this as rank-1, others disagree on rank-1
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


class SourceError(ValueError):
    """Raised when an input source file is unreadable or has the wrong shape."""


def _safe_load_json(path: Path, source_label: str) -> dict:
    """Read a JSON file, fail fast with a clear message on bad input.

    `source_label` is e.g. 'crg' so the error tells the user which --xxx flag
    pointed at the bad file. UnicodeDecodeError catches the `.db` mistake.
    """
    if path.suffix.lower() == ".db":
        raise SourceError(
            f"--{source_label} expects a JSON file (L1.json / graph.json), "
            f"not a SQLite database. Got: {path}"
        )
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as e:
        raise SourceError(
            f"--{source_label}: {path} is not UTF-8 text "
            f"(looks like a binary file): {e}"
        ) from e
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise SourceError(
            f"--{source_label}: {path} is not valid JSON: {e}"
        ) from e
    if not isinstance(data, dict):
        raise SourceError(
            f"--{source_label}: top-level JSON in {path} must be an object, "
            f"got {type(data).__name__}"
        )
    return data


def load_crg_hubs(path: Path, top_k: int) -> list[str]:
    if not path.exists():
        return []
    data = _safe_load_json(path, "crg")
    # CRG L1.json uses 'blast' for file-level impact ranking (file_path field).
    # Some variants emit 'BLAST'/'hubs' with {file|path|name}.
    for key in ("blast", "BLAST"):
        items = data.get(key)
        if items:
            out = []
            for it in items[:top_k]:
                if isinstance(it, dict):
                    f = it.get("file_path") or it.get("file") or it.get("path") or it.get("name")
                else:
                    f = it
                if f:
                    out.append(_normalize(f))
            if out:
                return out
    # hubs in CRG are symbol-level; fall back to symbol's containing file when needed
    items = data.get("hubs") or []
    out = []
    for it in items[:top_k]:
        if isinstance(it, dict):
            f = it.get("file_path") or it.get("file") or it.get("path") or it.get("name")
        else:
            f = it
        if f:
            out.append(_normalize(f))
    return out


def load_graphify_hubs(path: Path, top_k: int) -> list[str]:
    if not path.exists():
        return []
    data = _safe_load_json(path, "graphify")
    nodes = data.get("nodes", [])
    # graphify uses 'links' (networkx-style) more often than 'edges'
    edges = data.get("links") or data.get("edges") or []

    # Use precomputed centrality only when the field is actually present on nodes
    # (key existence check, not truthiness — otherwise centrality=0 looks "missing").
    centrality_keys = ("centrality", "pagerank", "degree")
    has_centrality = bool(nodes) and any(k in nodes[0] for k in centrality_keys)
    if has_centrality:
        def score(n):
            for k in centrality_keys:
                if k in n:
                    return n.get(k) or 0
            return 0
        code_nodes = [n for n in nodes if n.get("path") or n.get("file") or n.get("source_file") or n.get("id")]
        code_nodes.sort(key=score, reverse=True)
        out = []
        for n in code_nodes[:top_k]:
            f = n.get("path") or n.get("file") or n.get("source_file") or n.get("id")
            if f:
                out.append(_normalize(f))
        return out

    # Fallback: compute degree from links and aggregate per (normalized) source_file
    from collections import Counter, defaultdict
    deg: Counter = Counter()
    for e in edges:
        s = e.get("_src") or e.get("source") or e.get("from")
        t = e.get("_tgt") or e.get("target") or e.get("to")
        if s: deg[s] += 1
        if t: deg[t] += 1

    file_total: dict[str, int] = defaultdict(int)
    for n in nodes:
        sf = n.get("source_file") or n.get("path") or n.get("file")
        if sf and (str(sf).endswith(".py") or n.get("file_type") == "code"):
            file_total[_normalize(sf)] += deg.get(n.get("id"), 0)
    ranked = sorted(file_total.items(), key=lambda kv: -kv[1])
    return [f for f, _ in ranked[:top_k]]


def load_generic_hubs(path: Path, top_k: int, source_label: str = "generic") -> list[str]:
    if not path.exists():
        return []
    data = _safe_load_json(path, source_label)
    items = data.get("hubs") or data.get("top_files") or []
    out = []
    for it in items[:top_k]:
        if isinstance(it, dict):
            f = it.get("file") or it.get("path") or it.get("name")
        else:
            f = it
        if f:
            out.append(_normalize(f))
    return out


def _normalize(p: str) -> str:
    # strip leading ./ and absolute prefixes; keep posix
    p = p.strip()
    if p.startswith("./"):
        p = p[2:]
    return p.replace("\\", "/")


def consensus(sources: dict[str, list[str]], top_k: int) -> dict:
    file_votes: dict[str, set[str]] = defaultdict(set)
    file_ranks: dict[str, dict[str, int]] = defaultdict(dict)
    for src, hubs in sources.items():
        for i, f in enumerate(hubs[:top_k], start=1):
            file_votes[f].add(src)
            file_ranks[f][src] = i

    # Pre-compute rank-1 candidates across sources to derive DEBATE per row.
    rank1_by_src = {s: (h[0] if h else None) for s, h in sources.items()}
    rank1_files = {f for f in rank1_by_src.values() if f}
    debate = len(rank1_files) > 1
    rank1_sources_per_file: dict[str, list[str]] = defaultdict(list)
    for s, f in rank1_by_src.items():
        if f:
            rank1_sources_per_file[f].append(s)

    rows = []
    for f, voters in file_votes.items():
        n = len(voters)
        if n >= 3:
            label = "CONSENSUS"
        elif n == 2:
            label = "MAJORITY"
        else:
            label = "SINGLE"
        flags: list[str] = []
        is_debate = debate and f in rank1_files
        if is_debate:
            flags.append("DEBATE")
            # Keep count-based label (CONSENSUS/MAJORITY/SINGLE) and surface DEBATE
            # as an orthogonal flag — they encode different signals (broad agreement
            # vs. rank-1 disagreement). Earlier override hid the consensus signal.
        rows.append({
            "file": f,
            "label": label,
            "flags": flags,
            "voters": sorted(voters),
            "ranks": file_ranks[f],
            "vote_count": n,
            "rank1_sources": rank1_sources_per_file.get(f, []),
        })
    rows.sort(key=lambda r: (-r["vote_count"], min(r["ranks"].values())))

    return {
        "rows": rows,
        "rank1_by_source": rank1_by_src,
        "debate": debate,
        "sources_used": list(sources.keys()),
        "top_k": top_k,
    }


def render_md(result: dict) -> tuple[str, str]:
    rows = result["rows"]
    sources = result["sources_used"]

    md = ["# Hub Files — Multi-tool Consensus", ""]
    md.append(f"**Sources** ({len(sources)}): {', '.join(sources)}  ·  top_k = {result['top_k']}")
    if result["debate"]:
        md.append(f"\n> ⚠️  **DEBATE**: sources disagree on rank-1. See disagreements.md.\n")
    md.append("\n## Vote table\n")
    header_cols = ["File", "Label", "Votes", "Flags"] + [f"rank/{s}" for s in sources]
    md.append("| " + " | ".join(header_cols) + " |")
    md.append("|" + "|".join(["---"] * len(header_cols)) + "|")
    for r in rows:
        ranks = [str(r["ranks"].get(s, "—")) for s in sources]
        flags = ", ".join(r.get("flags", [])) or "—"
        md.append(
            "| `" + r["file"] + "` | " + r["label"] + " | "
            + str(r["vote_count"]) + " | " + flags + " | " + " | ".join(ranks) + " |"
        )
    md.append("")
    md.append("## Labels\n")
    md.append("- **CONSENSUS** (≥3 sources): high-confidence hub")
    md.append("- **MAJORITY** (2 sources): plausible hub, verify")
    md.append("- **SINGLE** (1 source): possible miss by other tools, or false positive")
    md.append("- **DEBATE** (rank-1 contested): some source declares this rank-1, others disagree")

    # Disagreements doc — list every contested rank-1 candidate
    dmd = ["# Disagreements", ""]
    dmd.append("## Rank-1 by source\n")
    for s, f in result["rank1_by_source"].items():
        dmd.append(f"- **{s}** → `{f or '—'}`")
    dmd.append("")
    debate_rows = [r for r in rows if "DEBATE" in r.get("flags", [])]
    if debate_rows:
        dmd.append("## DEBATE rank-1 candidates\n")
        for r in debate_rows:
            backers = ", ".join(r.get("rank1_sources", []))
            others = ", ".join(s for s in result["sources_used"] if s not in r.get("rank1_sources", []))
            dmd.append(
                f"- `{r['file']}` — rank-1 by: **{backers or '—'}**  ·  not rank-1 by: {others or '—'}"
            )
        dmd.append("")
    singles = [r for r in rows if r["label"] == "SINGLE"]
    if singles:
        dmd.append("## SINGLE-vote candidates (potential blind spots)\n")
        for r in singles[:20]:
            voter = r["voters"][0]
            dmd.append(f"- `{r['file']}` — only `{voter}` (rank {r['ranks'][voter]})")
    return "\n".join(md), "\n".join(dmd)


def main() -> int:
    p = argparse.ArgumentParser(
        description=(
            "Phase 4.5 — Multi-tool consensus on hub files. "
            "Pass `repo` as a positional to auto-derive --crg-l1/--graphify/--out "
            "from the standard skill layout."
        )
    )
    p.add_argument(
        "repo", type=Path, nargs="?", default=None,
        help="repo root (optional). If given, defaults are derived: "
             "--crg-l1 = <repo>/.claude/codebase-scan/evidence/L1.json, "
             "--graphify = <repo>/graphify-out/graph.json, "
             "--out = <repo>/.claude/codebase-scan/consensus.",
    )
    # `--crg-l1` is the preferred name (reflects the expected L1.json input).
    # `--crg` kept as alias for back-compat; deprecation warning emitted below.
    p.add_argument(
        "--crg-l1", "--crg", dest="crg", type=Path, default=None,
        help="CRG L1.json path (NOT graph.db). Default: <repo>/.claude/codebase-scan/evidence/L1.json",
    )
    p.add_argument(
        "--graphify", type=Path, default=None,
        help="graphify graph.json path. Default: <repo>/graphify-out/graph.json",
    )
    p.add_argument(
        "--codex", type=Path, default=None,
        help="codex-mcp hubs JSON (no default — pass explicit path)",
    )
    p.add_argument(
        "--antigravity", type=Path, default=None,
        help="antigravity-mcp hubs JSON (no default — pass explicit path)",
    )
    p.add_argument("--top-k", type=int, default=10)
    p.add_argument(
        "--out", type=Path, default=None,
        help="output dir. Default: <repo>/.claude/codebase-scan/consensus. Required if `repo` not given.",
    )
    args = p.parse_args()

    # Deprecation notice for old flag name (sys.argv detection — argparse aliases share dest)
    has_old = "--crg" in sys.argv
    has_new = "--crg-l1" in sys.argv
    if has_old and has_new:
        print(
            "[warn] both --crg and --crg-l1 given; argparse keeps the LAST one. "
            "Use --crg-l1 only.",
            file=sys.stderr,
        )
    elif has_old:
        print(
            "[warn] --crg is deprecated; prefer --crg-l1 (the input is L1.json, not graph.db)",
            file=sys.stderr,
        )

    # Derive defaults from positional repo. Explicit `--xxx` overrides the
    # derived default; warn so the override is visible (debuggability per round-2).
    if args.repo:
        repo = args.repo.resolve()
        if not repo.is_dir():
            print(f"[err] repo path is not a directory: {repo}", file=sys.stderr)
            return 2
        scan_root = repo / ".claude" / "codebase-scan"
        derived = {
            "--crg-l1":   ("crg",      scan_root / "evidence" / "L1.json"),
            "--graphify": ("graphify", repo / "graphify-out" / "graph.json"),
            "--out":      ("out",      scan_root / "consensus"),
        }
        for flag, (attr, default_path) in derived.items():
            if getattr(args, attr) is None:
                setattr(args, attr, default_path)
            else:
                print(
                    f"[warn] {flag} override active: using {getattr(args, attr)} "
                    f"(skill default would have been {default_path})",
                    file=sys.stderr,
                )

    if args.out is None:
        print(
            "[err] --out is required when no `repo` positional is given",
            file=sys.stderr,
        )
        return 2

    # Load each source. Failures degrade gracefully unless the user explicitly
    # passed the path — in that case we surface the error rather than silently
    # dropping the source.
    loaders = [
        ("crg",          args.crg,         load_crg_hubs,      "--crg-l1"),
        ("graphify",     args.graphify,    load_graphify_hubs, "--graphify"),
        ("codex",        args.codex,       load_generic_hubs,  "--codex"),
        ("antigravity",  args.antigravity, load_generic_hubs,  "--antigravity"),
    ]
    sources: dict[str, list[str]] = {}
    for name, path, loader, flag in loaders:
        if path is None:
            continue
        if not path.exists():
            print(f"[warn] {flag}: file not found, skipping: {path}", file=sys.stderr)
            continue
        try:
            if loader is load_generic_hubs:
                hubs = loader(path, args.top_k, source_label=name)
            else:
                hubs = loader(path, args.top_k)
        except SourceError as e:
            print(f"[err] {flag}: {e}", file=sys.stderr)
            return 2
        if hubs:
            sources[name] = hubs
        else:
            print(f"[warn] {flag}: loaded but 0 hubs found in {path}", file=sys.stderr)

    if len(sources) < 2:
        print(
            f"[err] need ≥2 sources, got {len(sources)}: {list(sources.keys())}",
            file=sys.stderr,
        )
        return 2

    result = consensus(sources, args.top_k)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "hubs-consensus.json").write_text(
        json.dumps(result, indent=2, ensure_ascii=False)
    )
    md, dmd = render_md(result)
    (args.out / "hubs-consensus.md").write_text(md)
    (args.out / "disagreements.md").write_text(dmd)
    print(f"[ok] consensus from {len(sources)} sources → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
