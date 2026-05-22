#!/usr/bin/env python3
"""debate_round2.py — Triangle Review Round 2 (selective multi-turn).

Two subcommands:

  prepare   Filter clusters by --mode (disagreement|both), render a Round 2
            batch prompt that all three peers will answer. Writes:
              <run_dir>/debate/targets.json     (machine-readable cluster list)
              <run_dir>/debate/round2_prompt.txt(prompt template)

  merge     Read three Round 2 verdict files
              <run_dir>/debate/{claude,codex,antigravity}_round2.json
            and fold verdicts back into the cluster set, recomputing severity
            with the same Q-A hybrid rule. Writes:
              <run_dir>/CODE-REVIEW.md          (regenerated with debate annotations)
              <run_dir>/debate/clusters_post.json

Modes:
  disagreement  Only DEBATE-flagged clusters re-tried (default, cheap).
  both          DEBATE + CONSENSUS clusters re-tried (paranoid).

Per-cluster verdict from each peer:
  {
    "cluster_id": "C-001",
    "action": "agree" | "revise" | "withdraw",
    "revised_severity": "critical|major|minor|info"   # required if action=="revise"
    "rationale": "<short>"
  }

Final severity rule after Round 2:
  - drop withdrawn reviewers from the cluster
  - if zero reviewers remain → cluster status DISMISSED
  - else recompute severity via Q-A hybrid on remaining {agree → orig, revise → revised_severity}
  - cluster status:
      DEBATE_RESOLVED   if Round 1 had DEBATE and Round 2 severity is uniform
      DEBATE_PERSISTED  if disagreement remains
      CONSENSUS_CONFIRMED  if Round 1 was CONSENSUS and Round 2 also uniform
      DISMISSED         if all reviewers withdrew
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from collections import defaultdict

# Reuse the consensus engine helpers
sys.path.insert(0, str(Path(__file__).resolve().parent))
from anchor_lines import anchor_finding  # type: ignore
import diff_findings  # type: ignore

REVIEWERS = ("claude", "codex", "antigravity")
SEV_RANK = {"info": 0, "minor": 1, "major": 2, "critical": 3}
SEV_BY_RANK = {v: k for k, v in SEV_RANK.items()}


# ---------- helpers ----------------------------------------------------------


def cluster_id_for(c: dict) -> str:
    raw = f"{c['file']}|{c['line_start']}-{c['line_end']}|{c['category']}"
    h = hashlib.sha1(raw.encode()).hexdigest()[:8]
    return f"C-{h}"


def load_clusters(run_dir: Path, repo_root: Path | None) -> tuple[list[dict], list[str]]:
    all_findings = []
    present = []
    for reviewer in REVIEWERS:
        findings, err = diff_findings.load_reviewer(run_dir, reviewer)
        if findings is None:
            continue
        present.append(reviewer)
        if repo_root:
            for f in findings:
                anchor_finding(f, repo_root)
        all_findings.extend(findings)
    clusters = diff_findings.cluster_findings(all_findings, tol=3)
    for c in clusters:
        diff_findings.classify_cluster(c, present)
        c["cluster_id"] = cluster_id_for(c)
    return clusters, present


# ---------- prepare ----------------------------------------------------------


def render_prompt(targets: list[dict], run_id: str) -> str:
    lines = []
    lines.append("ROLE: You are a peer reviewer in Round 2 of a Triangle Review.")
    lines.append(f"RUN_ID: {run_id}")
    lines.append("")
    lines.append("CONTEXT: Round 1 produced these clusters where your verdict is")
    lines.append("now being cross-examined. For each, decide whether you stand by")
    lines.append("your original severity, want to revise it, or want to withdraw")
    lines.append("the finding entirely (i.e., you no longer believe it is a real")
    lines.append("issue after seeing peer perspectives).")
    lines.append("")
    lines.append("Use mcp__serena__read_file with explicit start_line / end_line to")
    lines.append("re-verify each finding against the actual code before deciding.")
    lines.append("")
    lines.append("CLUSTERS UNDER DEBATE:")
    lines.append("")
    for c in targets:
        lines.append(f"## {c['cluster_id']}  [{c['confidence']}, severity={c['severity']}, debate={c['debate']}]")
        lines.append(f"- File: `{c['file']}` lines {c['line_start']}-{c['line_end']}")
        lines.append(f"- Category: {c['category']}")
        lines.append("- Round 1 votes:")
        for m in c["members"]:
            r = m.get("_reviewer", "?")
            sev = m.get("severity", "?")
            summ = m.get("summary", "")[:120]
            lines.append(f"  - {r} ({sev}): {summ}")
            detail = m.get("detail", "")
            if detail:
                lines.append(f"    > {detail[:300]}")
        lines.append("")

    lines.append("DELIVERABLE: Output ONE JSON object, no fence, no prose:")
    lines.append("")
    lines.append("{")
    lines.append('  "reviewer": "<your name>",')
    lines.append('  "round": 2,')
    lines.append(f'  "run_id": "{run_id}",')
    lines.append('  "verdicts": [')
    lines.append('    {')
    lines.append('      "cluster_id": "<echo>",')
    lines.append('      "action": "agree" | "revise" | "withdraw",')
    lines.append('      "revised_severity": "critical|major|minor|info",  // only if action=="revise"')
    lines.append('      "rationale": "<<=200 chars, cite code if you re-read>>"')
    lines.append('    }')
    lines.append("  ]")
    lines.append("}")
    lines.append("")
    lines.append("RULES:")
    lines.append("- One verdict per cluster_id listed above.")
    lines.append("- 'withdraw' means you now think this is NOT a real issue.")
    lines.append("- 'agree' means you keep your Round 1 severity.")
    lines.append("- Be honest. False positives downgraded here are the whole point.")
    return "\n".join(lines)


def cmd_prepare(args) -> int:
    run_dir = args.run_dir.resolve()
    repo_root = args.repo.resolve() if args.repo else None
    clusters, present = load_clusters(run_dir, repo_root)

    if args.mode == "disagreement":
        targets = [c for c in clusters if c["debate"]]
    elif args.mode == "both":
        targets = [c for c in clusters if c["debate"] or c["confidence"] == "CONSENSUS"]
    else:
        print(f"unknown mode: {args.mode}", file=sys.stderr)
        return 2

    if not targets:
        print(f"no clusters match --mode {args.mode}; nothing to debate", file=sys.stderr)
        return 0

    debate_dir = run_dir / "debate"
    debate_dir.mkdir(exist_ok=True)

    # Persist a stripped-down clusters snapshot for merge step
    targets_payload = [
        {
            "cluster_id": c["cluster_id"],
            "file": c["file"],
            "line_start": c["line_start"],
            "line_end": c["line_end"],
            "category": c["category"],
            "confidence": c["confidence"],
            "severity": c["severity"],
            "debate": c["debate"],
            "reviewers": c["reviewers"],
            "members": [
                {
                    "_reviewer": m.get("_reviewer"),
                    "id": m.get("id"),
                    "severity": m.get("severity"),
                    "summary": m.get("summary"),
                    "detail": m.get("detail"),
                }
                for m in c["members"]
            ],
        }
        for c in targets
    ]
    (debate_dir / "targets.json").write_text(json.dumps(targets_payload, indent=2, ensure_ascii=False))

    # Also persist all clusters so merge can recompose final report
    all_payload = [
        {**{k: v for k, v in c.items() if k != "members"},
         "members": [
             {
                 "_reviewer": m.get("_reviewer"),
                 "id": m.get("id"),
                 "severity": m.get("severity"),
                 "summary": m.get("summary"),
                 "detail": m.get("detail"),
             }
             for m in c["members"]
         ]}
        for c in clusters
    ]
    (debate_dir / "clusters_pre.json").write_text(json.dumps(all_payload, indent=2, ensure_ascii=False))

    prompt = render_prompt(targets, run_id=run_dir.name)
    (debate_dir / "round2_prompt.txt").write_text(prompt)

    print(f"prepared {len(targets)} debate target(s) [mode={args.mode}, present={present}]")
    print(f"  targets: {debate_dir / 'targets.json'}")
    print(f"  prompt:  {debate_dir / 'round2_prompt.txt'}")
    print()
    print("Next: orchestrator dispatches the prompt to each peer, saving responses to:")
    for r in REVIEWERS:
        print(f"  {debate_dir / f'{r}_round2.json'}")
    print(f"Then run: python3 {Path(__file__).name} merge --run-dir <dir> [--repo <repo>]")
    return 0


# ---------- merge ------------------------------------------------------------


def apply_verdicts(cluster: dict, verdicts_by_reviewer: dict[str, dict]) -> dict:
    """Mutate cluster in place with Round 2 outcome."""
    members = cluster["members"]
    cluster["round2"] = {}
    new_members = []
    for m in members:
        r = m.get("_reviewer")
        v = verdicts_by_reviewer.get(r)
        if not v:
            new_members.append(m)
            cluster["round2"][r] = {"action": "no_response"}
            continue
        action = v.get("action", "agree")
        cluster["round2"][r] = {
            "action": action,
            "rationale": v.get("rationale", ""),
            "revised_severity": v.get("revised_severity"),
        }
        if action == "withdraw":
            continue
        if action == "revise" and v.get("revised_severity") in SEV_RANK:
            m = dict(m)
            m["severity"] = v["revised_severity"]
            m["_round2_revised"] = True
        new_members.append(m)
    cluster["members"] = new_members

    # Recompute confidence + severity
    if not new_members:
        cluster["confidence"] = "DISMISSED"
        cluster["severity"] = "info"
        cluster["debate"] = False
        cluster["status"] = "DISMISSED"
        cluster["reviewers"] = []
        return cluster

    reviewers_now = sorted({m.get("_reviewer") for m in new_members})
    cluster["reviewers"] = reviewers_now
    n = len(reviewers_now)
    if n >= 3:
        confidence = "CONSENSUS"
    elif n == 2:
        confidence = "MAJORITY"
    else:
        confidence = "SINGLE"

    sevs = [m.get("severity", "info") for m in new_members]
    unique = set(sevs)
    if len(unique) == 1:
        new_sev = sevs[0]
        debate = False
    elif "critical" in unique:
        new_sev = "critical"
        debate = True
    else:
        new_sev = SEV_BY_RANK[max(SEV_RANK.get(s, 0) for s in sevs)]
        debate = True

    was_debate = cluster.get("debate", False)
    was_consensus = cluster.get("confidence") == "CONSENSUS"

    cluster["confidence"] = confidence
    cluster["severity"] = new_sev
    cluster["debate"] = debate

    if was_debate and not debate:
        cluster["status"] = "DEBATE_RESOLVED"
    elif was_debate and debate:
        cluster["status"] = "DEBATE_PERSISTED"
    elif was_consensus and confidence == "CONSENSUS" and not debate:
        cluster["status"] = "CONSENSUS_CONFIRMED"
    else:
        cluster["status"] = "REVISED"

    return cluster


def render_round2_block(cluster: dict) -> list[str]:
    out = []
    r2 = cluster.get("round2", {})
    if not r2:
        return out
    out.append("- **Round 2 verdicts**:")
    for r in REVIEWERS:
        v = r2.get(r)
        if not v:
            continue
        action = v.get("action", "?")
        rev = v.get("revised_severity")
        rat = v.get("rationale", "").strip()
        chunk = f"  - **{r}**: `{action}`"
        if action == "revise" and rev:
            chunk += f" → severity={rev}"
        if rat:
            chunk += f" — {rat[:200]}"
        out.append(chunk)
    return out


def render_post_report(run_id: str, clusters: list[dict], present: list[str]) -> str:
    buckets = defaultdict(list)
    debate_persisted = []
    dismissed = []
    for c in clusters:
        if c.get("status") == "DISMISSED":
            dismissed.append(c)
            continue
        if c.get("status") == "DEBATE_PERSISTED":
            debate_persisted.append(c)
        buckets[c["confidence"]].append(c)

    out = []
    out.append("# Triangle Review Report (Round 2)")
    out.append("")
    out.append(f"- **Run ID**: `{run_id}`")
    out.append(f"- **Reviewers present**: {', '.join(present) if present else '(none)'}")
    out.append(f"- **Round 2 applied**: yes")
    out.append("")
    out.append("## Summary")
    out.append("")
    out.append(f"- CONSENSUS (HIGH): **{len(buckets['CONSENSUS'])}**")
    out.append(f"- MAJORITY (MEDIUM): **{len(buckets['MAJORITY'])}**")
    out.append(f"- SINGLE (LOW): **{len(buckets['SINGLE'])}**")
    out.append(f"- DEBATE_PERSISTED: **{len(debate_persisted)}**")
    out.append(f"- DISMISSED (all withdrew): **{len(dismissed)}**")
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
            head = f"### [{c['severity'].upper()}] {c['file']}:{c['line_start']}-{c['line_end']} — {c['category']}"
            out.append(head)
            out.append(f"- **Cluster ID**: `{c.get('cluster_id', '?')}`")
            status = c.get("status")
            if status:
                out.append(f"- **Round 2 status**: {status}")
            out.append(
                f"- **Reviewers**: {', '.join(c.get('reviewers', []))}"
            )
            if c.get("debate"):
                out.append("- **DEBATE**: severity disagreement persists")
            out.append("")
            for m in c["members"]:
                tag = " (revised)" if m.get("_round2_revised") else ""
                out.append(f"**{m['_reviewer']}** ({m.get('severity', '?')}{tag}): {m.get('summary', '')}")
                detail = (m.get("detail") or "").strip()
                if detail:
                    for dl in detail.splitlines():
                        out.append(f"> {dl}")
                out.append("")
            for line in render_round2_block(c):
                out.append(line)
            out.append("")

    section("CONSENSUS (3/3)", buckets["CONSENSUS"])
    section("MAJORITY (2/3)", buckets["MAJORITY"])
    section("SINGLE (1/3)", buckets["SINGLE"])
    section("DEBATE_PERSISTED", debate_persisted)
    section("DISMISSED", dismissed)

    return "\n".join(out) + "\n"


def cmd_merge(args) -> int:
    run_dir = args.run_dir.resolve()
    debate_dir = run_dir / "debate"
    if not debate_dir.is_dir():
        print(f"no debate dir at {debate_dir} — run prepare first", file=sys.stderr)
        return 2

    clusters_pre = json.loads((debate_dir / "clusters_pre.json").read_text())

    verdicts_by_cluster: dict[str, dict[str, dict]] = defaultdict(dict)
    present = []
    for r in REVIEWERS:
        path = debate_dir / f"{r}_round2.json"
        if not path.is_file():
            print(f"[skip] {r} round2: missing {path.name}", file=sys.stderr)
            continue
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError as e:
            print(f"[skip] {r} round2 parse error: {e}", file=sys.stderr)
            continue
        present.append(r)
        for v in data.get("verdicts", []):
            cid = v.get("cluster_id")
            if not cid:
                continue
            verdicts_by_cluster[cid][r] = v

    # Apply
    for c in clusters_pre:
        cid = c.get("cluster_id")
        if cid in verdicts_by_cluster:
            apply_verdicts(c, verdicts_by_cluster[cid])
        else:
            c["status"] = "NOT_DEBATED"

    out_md = run_dir / "CODE-REVIEW.md"
    out_md.write_text(render_post_report(run_dir.name, clusters_pre, present))
    (debate_dir / "clusters_post.json").write_text(json.dumps(clusters_pre, indent=2, ensure_ascii=False))

    n_dismissed = sum(1 for c in clusters_pre if c.get("status") == "DISMISSED")
    n_resolved = sum(1 for c in clusters_pre if c.get("status") == "DEBATE_RESOLVED")
    n_persisted = sum(1 for c in clusters_pre if c.get("status") == "DEBATE_PERSISTED")
    n_confirmed = sum(1 for c in clusters_pre if c.get("status") == "CONSENSUS_CONFIRMED")
    print(
        f"merged Round 2: dismissed={n_dismissed}, resolved={n_resolved}, "
        f"persisted={n_persisted}, consensus_confirmed={n_confirmed}"
    )
    print(f"wrote {out_md}")
    return 0


# ---------- main -------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_prep = sub.add_parser("prepare")
    p_prep.add_argument("--run-dir", required=True, type=Path)
    p_prep.add_argument("--repo", type=Path, default=None,
                        help="repo root for anchor_lines preprocessing (recommended)")
    p_prep.add_argument("--mode", choices=["disagreement", "both"], default="disagreement")
    p_prep.set_defaults(func=cmd_prepare)

    p_merge = sub.add_parser("merge")
    p_merge.add_argument("--run-dir", required=True, type=Path)
    p_merge.set_defaults(func=cmd_merge)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
