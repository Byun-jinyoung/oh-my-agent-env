#!/usr/bin/env python3
"""
diff_findings.py — Triangle Review consensus engine.

Reads claude.json / codex.json / gemini.json from --run-dir, clusters findings
by (file, line-overlap±tol, category), applies Q-A hybrid severity rule, and
emits CODE-REVIEW.md.

Usage:
    python3 diff_findings.py --run-dir .claude/triangle-review/<run_id> \
        --out CODE-REVIEW.md [--tol 3]
"""
import argparse
import json
import sys
from pathlib import Path
from collections import defaultdict

try:
    from anchor_lines import anchor_finding  # type: ignore
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from anchor_lines import anchor_finding  # type: ignore

SEV_RANK = {"info": 0, "minor": 1, "major": 2, "critical": 3}
SEV_BY_RANK = {v: k for k, v in SEV_RANK.items()}
REVIEWERS = ("claude", "codex", "gemini")


def load_reviewer(run_dir: Path, reviewer: str):
    path = run_dir / f"{reviewer}.json"
    if not path.exists():
        return None, f"missing file: {path.name}"
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        return None, f"JSON parse error in {path.name}: {e}"
    findings = data.get("findings", [])
    for f in findings:
        f["_reviewer"] = reviewer
    return findings, None


def overlaps(a_start, a_end, b_start, b_end, tol):
    return max(a_start, b_start) - tol <= min(a_end, b_end) + tol


def cluster_findings(all_findings, tol):
    clusters = []
    for f in all_findings:
        matched = None
        for c in clusters:
            if c["file"] != f.get("file"):
                continue
            if c["category"] != f.get("category"):
                continue
            if overlaps(
                c["line_start"], c["line_end"],
                f.get("line_start", 0), f.get("line_end", 0),
                tol,
            ):
                matched = c
                break
        if matched is None:
            matched = {
                "file": f.get("file"),
                "category": f.get("category"),
                "line_start": f.get("line_start", 0),
                "line_end": f.get("line_end", 0),
                "members": [],
            }
            clusters.append(matched)
        matched["members"].append(f)
        matched["line_start"] = min(matched["line_start"], f.get("line_start", 0))
        matched["line_end"] = max(matched["line_end"], f.get("line_end", 0))
    return clusters


def resolve_severity(members):
    sevs = [m.get("severity", "info") for m in members]
    unique = set(sevs)
    if len(unique) == 1:
        return sevs[0], False
    if "critical" in unique:
        return "critical", True
    max_rank = max(SEV_RANK.get(s, 0) for s in sevs)
    return SEV_BY_RANK[max_rank], True


def classify_cluster(cluster, present_reviewers):
    reviewers_in_cluster = sorted({m["_reviewer"] for m in cluster["members"]})
    n = len(reviewers_in_cluster)
    missing = [r for r in present_reviewers if r not in reviewers_in_cluster]
    if n >= 3 or (n == len(present_reviewers) and n >= 2 and not missing):
        confidence = "CONSENSUS" if n == 3 else "MAJORITY"
    elif n == 2:
        confidence = "MAJORITY"
    else:
        confidence = "SINGLE"
    severity, debate = resolve_severity(cluster["members"])
    cluster["reviewers"] = reviewers_in_cluster
    cluster["missing"] = missing
    cluster["confidence"] = confidence
    cluster["severity"] = severity
    cluster["debate"] = debate
    return cluster


def render_cluster(c):
    head = f"### [{c['severity'].upper()}] {c['file']}:{c['line_start']}-{c['line_end']} — {c['category']}"
    lines = [head]
    lines.append(f"- **Reviewers**: {', '.join(c['reviewers'])}"
                 + (f" (missing: {', '.join(c['missing'])})" if c["missing"] else ""))
    if c["debate"]:
        lines.append("- **DEBATE**: severity disagreement — human review required")
    ev_union = sorted({e for m in c["members"] for e in (m.get("evidence_ids") or [])})
    if ev_union:
        lines.append(f"- **Evidence**: {', '.join(ev_union)}")
    lines.append("")
    for m in c["members"]:
        lines.append(f"**{m['_reviewer']}** ({m.get('severity', '?')}): {m.get('summary', '')}")
        detail = m.get("detail", "").strip()
        if detail:
            for dl in detail.splitlines():
                lines.append(f"> {dl}")
        sug = m.get("suggestion", "").strip() if m.get("suggestion") else ""
        if sug:
            lines.append(f"  - *suggestion*: {sug}")
        lines.append("")
    return "\n".join(lines)


def render_report(run_id, present, absent, clusters):
    buckets = defaultdict(list)
    debate_bucket = []
    for c in clusters:
        buckets[c["confidence"]].append(c)
        if c["debate"]:
            debate_bucket.append(c)

    n_consensus = len(buckets["CONSENSUS"])
    n_majority = len(buckets["MAJORITY"])
    n_single = len(buckets["SINGLE"])
    n_debate = len(debate_bucket)

    out = []
    out.append("# Triangle Review Report")
    out.append("")
    out.append(f"- **Run ID**: `{run_id}`")
    out.append(f"- **Reviewers present**: {', '.join(present) if present else '(none)'}")
    if absent:
        out.append(f"- **Reviewers missing**: {', '.join(absent)}")
    out.append("")
    out.append("## Summary")
    out.append("")
    out.append(f"- CONSENSUS (HIGH): **{n_consensus}**")
    out.append(f"- MAJORITY (MEDIUM): **{n_majority}**")
    out.append(f"- SINGLE (LOW): **{n_single}**")
    out.append(f"- DEBATE flagged: **{n_debate}**")
    out.append("")

    def section(title, items):
        out.append(f"## {title}")
        out.append("")
        if not items:
            out.append("_(none)_")
            out.append("")
            return
        items_sorted = sorted(
            items,
            key=lambda c: (-SEV_RANK.get(c["severity"], 0), c["file"], c["line_start"]),
        )
        for c in items_sorted:
            out.append(render_cluster(c))

    section("CONSENSUS (3/3)", buckets["CONSENSUS"])
    section("MAJORITY (2/3)", buckets["MAJORITY"])
    section("SINGLE (1/3)", buckets["SINGLE"])
    section("DEBATE — severity disagreement", debate_bucket)

    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--tol", type=int, default=3, help="line overlap tolerance")
    ap.add_argument("--repo", type=Path, default=None,
                    help="repo root for anchor_lines preprocessing (recommended)")
    ap.add_argument("--no-anchor", action="store_true",
                    help="skip anchor_lines preprocessing")
    args = ap.parse_args()

    if not args.run_dir.is_dir():
        print(f"ERROR: run-dir not found: {args.run_dir}", file=sys.stderr)
        sys.exit(2)

    all_findings = []
    present = []
    absent = []
    run_id = args.run_dir.name

    repo_root = args.repo.resolve() if args.repo else None
    do_anchor = repo_root is not None and not args.no_anchor

    anchor_stats = {"verified": 0, "envelope": 0, "tolerance": 0,
                    "corrected": 0, "no_anchor": 0, "other": 0}

    for reviewer in REVIEWERS:
        findings, err = load_reviewer(args.run_dir, reviewer)
        if findings is None:
            absent.append(reviewer)
            print(f"[skip] {reviewer}: {err}", file=sys.stderr)
            continue
        present.append(reviewer)
        if do_anchor:
            for f in findings:
                anchor_finding(f, repo_root)
                st = f.get("line_anchor_status", "")
                if st == "envelope_verified":
                    anchor_stats["envelope"] += 1
                elif st == "verified":
                    anchor_stats["verified"] += 1
                elif st.startswith("verified_within"):
                    anchor_stats["tolerance"] += 1
                elif st.startswith("corrected"):
                    anchor_stats["corrected"] += 1
                elif st == "no_anchor":
                    anchor_stats["no_anchor"] += 1
                else:
                    anchor_stats["other"] += 1
            # persist anchored JSON back so users can inspect
            json_path = args.run_dir / f"{reviewer}.json"
            data = json.loads(json_path.read_text())
            data["findings"] = [
                {k: v for k, v in f.items() if k != "_reviewer"} for f in findings
            ]
            json_path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
        all_findings.extend(findings)

    if not present:
        print("ERROR: no reviewer JSON files found", file=sys.stderr)
        sys.exit(3)

    clusters = cluster_findings(all_findings, args.tol)
    for c in clusters:
        classify_cluster(c, present)

    report = render_report(run_id, present, absent, clusters)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report)
    msg = f"wrote {args.out} ({len(clusters)} clusters, reviewers: {','.join(present)})"
    if do_anchor:
        total = sum(anchor_stats.values())
        good = anchor_stats["envelope"] + anchor_stats["verified"] + anchor_stats["tolerance"] + anchor_stats["corrected"]
        msg += f" | anchor: {good}/{total} usable"
    print(msg)


if __name__ == "__main__":
    main()
