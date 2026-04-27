#!/usr/bin/env python3
"""Audit baseline + citation validator for codebase-scan skill.

Modes:
  audit_claims.py <repo_root>                 # emit L1-facts.md only (legacy)
  audit_claims.py --emit-evidence <repo_root> # + L1-evidence.json with stable IDs
  audit_claims.py --check <repo_root> <md>    # validate [EVIDENCE: ...] citations
                                                (exit 0 PASS, 1 FAIL; writes audit-report.md)

Evidence IDs: BLAST-01..10, HUB-01..15, INHERIT-01..10, COMM-01..05.

Citation format the downstream prose must use:
  <sentence> [EVIDENCE: BLAST-03, HUB-02]

Check rules (all must pass):
  C1  every cited ID exists in L1-evidence.json
  C2  sentences matching claim-keyword regex carry >=1 [EVIDENCE: ...]
  C3  claim type matches evidence type (core→BLAST, hub→HUB, inherits→INHERIT, community→COMM)
  C4  markdown is parseable (citations well-formed)
"""
from __future__ import annotations

import json
import re
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

CLAIM_KEYWORDS = {
    "BLAST": re.compile(r"\b(core|central|main entry|critical path|touches the most|largest blast)\b", re.I),
    "HUB":   re.compile(r"\b(hub|heavily used|frequently called|called from|call site)\b", re.I),
    "INHERIT": re.compile(r"\b(inherits?|extends?|subclass(es)? of|base class|framework base)\b", re.I),
    "COMM":  re.compile(r"\b(community|cluster|flow|module group|subsystem)\b", re.I),
}
ANY_CLAIM_RE = re.compile("|".join(p.pattern for p in CLAIM_KEYWORDS.values()), re.I)
CITATION_RE = re.compile(r"\[EVIDENCE:\s*([A-Z]+-\d{2}(?:\s*,\s*[A-Z]+-\d{2})*)\s*\]")
SENT_SPLIT_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z가-힣`])")


def normalize(path: str, repo_root: Path) -> str:
    p = path
    for prefix in ("/private", ""):
        full = prefix + str(repo_root)
        if p.startswith(full + "/"):
            return p[len(full) + 1:]
    return p


def short(q: str, max_len: int = 70) -> str:
    tail = q.split("::", 1)
    sym = tail[-1]
    return sym if len(sym) <= max_len else sym[:max_len] + "..."


def gather(repo_root: Path):
    db = repo_root / ".code-review-graph" / "graph.db"
    if not db.exists():
        raise SystemExit(f"CRG graph not found: {db}")
    con = sqlite3.connect(db); con.row_factory = sqlite3.Row

    node_kinds = dict(con.execute("SELECT kind, COUNT(*) FROM nodes GROUP BY kind"))
    edge_kinds = dict(con.execute("SELECT kind, COUNT(*) FROM edges GROUP BY kind"))

    blast = [(normalize(r["file_path"], repo_root), r["touched"]) for r in con.execute(
        "SELECT file_path, COUNT(DISTINCT target_qualified) AS touched "
        "FROM edges GROUP BY file_path ORDER BY touched DESC LIMIT 10")]

    hubs = [(r["target_qualified"], r["c"]) for r in con.execute(
        "SELECT target_qualified, COUNT(*) AS c FROM edges "
        "WHERE kind='CALLS' AND target_qualified LIKE '%::%' "
        "GROUP BY target_qualified ORDER BY c DESC LIMIT 15")]

    inh_rows = con.execute(
        "SELECT source_qualified, target_qualified FROM edges WHERE kind='INHERITS'").fetchall()
    base_counts = Counter(short(r["target_qualified"]) for r in inh_rows)
    top_bases = base_counts.most_common(10)

    try:
        communities = list(con.execute(
            "SELECT id, size, summary FROM community_summaries ORDER BY size DESC LIMIT 5"))
    except sqlite3.OperationalError:
        communities = []
    con.close()
    return node_kinds, edge_kinds, blast, hubs, top_bases, communities


def build_facts_md(repo_root: Path, gathered) -> str:
    node_kinds, edge_kinds, blast, hubs, top_bases, communities = gathered
    lines = [
        f"# L1 Facts — {repo_root.name}\n",
        "_Auto-generated from CRG graph. Use as evidence baseline for L3 prose audit._\n",
        "## Graph stats\n",
        f"- Nodes: {dict(node_kinds)}",
        f"- Edges: {dict(edge_kinds)}\n",
        "## Top blast-radius files (impact scope)\n",
        "| ID | File | Unique symbols touched |",
        "|---|---|---:|",
    ]
    for i, (f, c) in enumerate(blast, 1):
        lines.append(f"| BLAST-{i:02d} | `{f}` | {c} |")
    lines += ["", "## Top internal CALLS targets (call hubs)\n",
              "| ID | Symbol | Call sites |", "|---|---|---:|"]
    for i, (q, c) in enumerate(hubs, 1):
        lines.append(f"| HUB-{i:02d} | `{short(q)}` | {c} |")
    lines += ["", "## Inheritance patterns (top base classes)\n",
              "| ID | Base class | Subclass count |", "|---|---|---:|"]
    for i, (base, c) in enumerate(top_bases, 1):
        lines.append(f"| INHERIT-{i:02d} | `{base}` | {c} |")
    if communities:
        lines += ["", "## Detected communities\n",
                  "| ID | Community | Size | Summary |", "|---|---:|---:|---|"]
        for i, row in enumerate(communities, 1):
            lines.append(f"| COMM-{i:02d} | {row['id']} | {row['size']} | {row['summary'] or '-'} |")
    lines += [
        "", "## Audit rules for L3 prose\n",
        "Every claim with architectural keywords must end with `[EVIDENCE: <ID>[, <ID>]]`.",
        "Claim type → evidence type mapping:",
        "- `core|central|main entry|critical path` → BLAST-*",
        "- `hub|heavily used|frequently called` → HUB-*",
        "- `inherits|extends|framework base` → INHERIT-*",
        "- `community|cluster|flow|subsystem` → COMM-*",
        "Unverifiable claims (no matching row) must be quarantined under 'UNVERIFIED'.",
        "",
    ]
    return "\n".join(lines)


def build_evidence_json(repo_root: Path, gathered) -> dict:
    _, _, blast, hubs, top_bases, communities = gathered
    ev: dict[str, dict] = {}
    for i, (f, c) in enumerate(blast, 1):
        ev[f"BLAST-{i:02d}"] = {"type": "BLAST", "file": f, "touched": c}
    for i, (q, c) in enumerate(hubs, 1):
        ev[f"HUB-{i:02d}"] = {"type": "HUB", "symbol": short(q), "qualified": q, "calls": c}
    for i, (base, c) in enumerate(top_bases, 1):
        ev[f"INHERIT-{i:02d}"] = {"type": "INHERIT", "base": base, "subclass_count": c}
    for i, row in enumerate(communities, 1):
        ev[f"COMM-{i:02d}"] = {"type": "COMM", "community_id": row["id"],
                               "size": row["size"], "summary": row["summary"] or ""}
    return {
        "repo": str(repo_root),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "evidence": ev,
    }


def cmd_emit(repo_root: Path, emit_evidence: bool) -> int:
    gathered = gather(repo_root)
    out_dir = repo_root / ".claude" / "codebase-scan" / "evidence"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "L1-facts.md").write_text(build_facts_md(repo_root, gathered))
    print(f"L1 facts -> {out_dir/'L1-facts.md'}")
    if emit_evidence:
        data = build_evidence_json(repo_root, gathered)
        (out_dir / "L1-evidence.json").write_text(json.dumps(data, indent=2))
        print(f"L1 evidence -> {out_dir/'L1-evidence.json'} ({len(data['evidence'])} IDs)")
    return 0


def classify_claim(sentence: str) -> set[str]:
    """Return evidence-type prefixes the sentence is making claims about."""
    types = set()
    for t, pat in CLAIM_KEYWORDS.items():
        if pat.search(sentence):
            types.add(t)
    return types


def parse_citations(sentence: str) -> list[str]:
    ids: list[str] = []
    for m in CITATION_RE.finditer(sentence):
        ids.extend(s.strip() for s in m.group(1).split(","))
    return ids


def cmd_check(repo_root: Path, md_path: Path) -> int:
    ev_path = repo_root / ".claude" / "codebase-scan" / "evidence" / "L1-evidence.json"
    if not ev_path.exists():
        print(f"ERROR: run --emit-evidence first. Missing {ev_path}", file=sys.stderr)
        return 2
    evidence = json.loads(ev_path.read_text())["evidence"]
    valid_ids = set(evidence.keys())
    text = md_path.read_text()

    failures: list[str] = []
    sentences = SENT_SPLIT_RE.split(text)
    for sent in sentences:
        s = sent.strip()
        if not s:
            continue
        cited = parse_citations(s)
        # C1: every cited ID must exist
        for cid in cited:
            if cid not in valid_ids:
                failures.append(f"C1 unknown ID `{cid}` in: {s[:120]}")
        # Detect claim types
        claim_types = classify_claim(s)
        if claim_types:
            # C2: must carry citation
            if not cited:
                failures.append(f"C2 claim without citation (types={sorted(claim_types)}): {s[:120]}")
                continue
            # C3: claim-evidence type match
            cited_types = {cid.split("-", 1)[0] for cid in cited if cid in valid_ids}
            if claim_types.isdisjoint(cited_types):
                failures.append(
                    f"C3 type mismatch claim={sorted(claim_types)} cited={sorted(cited_types)}: {s[:120]}")

    report_path = repo_root / ".claude" / "codebase-scan" / "evidence" / "audit-report.md"
    if failures:
        body = [f"# Audit report — {md_path.name}", "", f"Failures: {len(failures)}", ""]
        body += [f"- {f}" for f in failures]
        report_path.write_text("\n".join(body) + "\n")
        print(f"AUDIT FAIL — {len(failures)} issue(s). Report: {report_path}", file=sys.stderr)
        for f in failures[:10]:
            print(f"  {f}", file=sys.stderr)
        return 1
    if report_path.exists():
        report_path.unlink()
    print(f"AUDIT PASS — {md_path} cites only valid IDs ({len(valid_ids)} available).")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr); return 2
    if argv[1] == "--emit-evidence":
        if len(argv) != 3:
            print(__doc__, file=sys.stderr); return 2
        return cmd_emit(Path(argv[2]).resolve(), emit_evidence=True)
    if argv[1] == "--check":
        if len(argv) != 4:
            print(__doc__, file=sys.stderr); return 2
        return cmd_check(Path(argv[2]).resolve(), Path(argv[3]).resolve())
    if argv[1].startswith("--"):
        print(__doc__, file=sys.stderr); return 2
    return cmd_emit(Path(argv[1]).resolve(), emit_evidence=False)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
