#!/usr/bin/env python3
"""anchor_lines.py — auto-correct line_start/line_end in peer findings.

Algorithm:
1. Extract code snippets quoted in finding.detail/summary (backtick-delimited).
2. Search those snippets in the actual target file.
3. Rewrite line_start/line_end to match grep result.
4. Annotate each finding with line_anchor_status:
   - verified  : reported lines already correct (within tolerance)
   - corrected : lines rewritten to match snippet hit
   - drift_<N> : corrected, original was off by N lines (for telemetry)
   - no_anchor : no usable snippet found, lines kept as-is
   - file_missing : finding.file not present in repo

Designed for triangle-review Phase 3.5 (between peer JSON load and cluster merge).

Usage:
    python3 anchor_lines.py --repo <repo_root> --in <peer.json> --out <peer.json.anchored>
    python3 anchor_lines.py --repo <repo_root> --run-dir <dir>   # process all *.json in dir
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# ---- snippet extraction --------------------------------------------------

# inline backtick: `...` (non-greedy, no nested backtick)
INLINE_RX = re.compile(r"`([^`\n]{6,200})`")
# triple-backtick block: ```...``` (multi-line)
BLOCK_RX = re.compile(r"```(?:\w+)?\n(.{6,2000}?)\n```", re.DOTALL)

# snippets that are too generic to anchor reliably
GENERIC_TOKENS = {
    "True",
    "False",
    "None",
    "self",
    "cfg",
    "args",
    "log",
    "torch",
    "subprocess",
    "os",
    "from",
    "import",
}


def is_generic(snippet: str) -> bool:
    s = snippet.strip()
    if len(s) < 6:
        return True
    if s in GENERIC_TOKENS:
        return True
    # Single bare identifier (no dot, no operator, ≤ 6 chars) → too generic
    # `cfg.paths.output_dir` is specific; `cfg` alone is not.
    if "." not in s and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,5}", s):
        return True
    return False


def extract_snippets(text: str) -> list[str]:
    if not text:
        return []
    out: list[str] = []
    for m in BLOCK_RX.finditer(text):
        out.append(m.group(1).strip())
    for m in INLINE_RX.finditer(text):
        out.append(m.group(1).strip())
    # de-dup, preserve order
    seen: set[str] = set()
    result: list[str] = []
    for s in out:
        if s not in seen and not is_generic(s):
            seen.add(s)
            result.append(s)
    return result


# ---- line search ---------------------------------------------------------

WS_RX = re.compile(r"\s+")


def normalize(s: str) -> str:
    return WS_RX.sub(" ", s).strip()


@dataclass
class Hit:
    line_start: int
    line_end: int
    snippet: str
    method: str  # "exact" | "normalized" | "substring"


def search_snippet(snippet: str, file_lines: list[str]) -> Hit | None:
    # 1) exact substring match in a single line
    for i, line in enumerate(file_lines, 1):
        if snippet in line:
            return Hit(i, i, snippet, "exact")
    # 2) normalized whitespace match in single line
    norm_snip = normalize(snippet)
    if norm_snip:
        for i, line in enumerate(file_lines, 1):
            if norm_snip in normalize(line):
                return Hit(i, i, snippet, "normalized")
    # 3) multi-line block match (snippet contains newline)
    if "\n" in snippet:
        snip_lines = [normalize(ln) for ln in snippet.split("\n") if normalize(ln)]
        if not snip_lines:
            return None
        # window over file
        norm_file = [normalize(ln) for ln in file_lines]
        first = snip_lines[0]
        for i, line in enumerate(norm_file):
            if first and first in line:
                # check subsequent lines roughly match
                if all(
                    i + j < len(norm_file) and snip_lines[j] in norm_file[i + j]
                    for j in range(len(snip_lines))
                ):
                    return Hit(i + 1, i + len(snip_lines), snippet, "multiline")
    # 4) substring of any token >=20 chars (rare fallback)
    if len(snippet) >= 20:
        for i, line in enumerate(file_lines, 1):
            if snippet[:20] in line:
                return Hit(i, i, snippet, "substring")
    return None


# ---- finding rewriting ---------------------------------------------------


def anchor_finding(finding: dict, repo_root: Path) -> dict:
    file_rel = finding.get("file", "")
    if not file_rel:
        finding["line_anchor_status"] = "no_file_field"
        return finding
    file_path = repo_root / file_rel
    if not file_path.is_file():
        finding["line_anchor_status"] = "file_missing"
        return finding

    file_lines = file_path.read_text(encoding="utf-8", errors="replace").splitlines()
    snippets = extract_snippets(finding.get("detail", "")) + extract_snippets(
        finding.get("summary", "")
    )
    if not snippets:
        finding["line_anchor_status"] = "no_quoted_snippet"
        return finding

    # Find all hits, prefer earliest match
    hits: list[Hit] = []
    for snip in snippets:
        h = search_snippet(snip, file_lines)
        if h:
            hits.append(h)

    if not hits:
        finding["line_anchor_status"] = "no_anchor"
        return finding

    # Span of all hits = anchor span
    anchor_start = min(h.line_start for h in hits)
    anchor_end = max(h.line_end for h in hits)

    orig_start = int(finding.get("line_start", 0) or 0)
    orig_end = int(finding.get("line_end", 0) or 0)

    finding["line_start_original"] = orig_start
    finding["line_end_original"] = orig_end
    finding["line_anchor_hits"] = [
        {"line_start": h.line_start, "line_end": h.line_end, "method": h.method, "snippet": h.snippet[:80]}
        for h in hits
    ]

    # Envelope rule: if peer's original range fully contains the anchor span
    # AND the original range is reasonably tight, keep peer's range — they
    # correctly cited a wider structural unit (e.g. a function span).
    envelope = (
        orig_start > 0
        and orig_end >= orig_start
        and orig_start <= anchor_start
        and anchor_end <= orig_end
        and (orig_end - orig_start) <= 60  # cap: don't keep absurdly wide ranges
    )
    if envelope:
        finding["line_anchor_status"] = "envelope_verified"
        return finding

    drift_start = abs(anchor_start - orig_start)
    drift_end = abs(anchor_end - orig_end)
    drift = max(drift_start, drift_end)

    finding["line_start"] = anchor_start
    finding["line_end"] = anchor_end

    if drift == 0:
        finding["line_anchor_status"] = "verified"
    elif drift <= 3:
        finding["line_anchor_status"] = f"verified_within_tolerance_{drift}"
    else:
        finding["line_anchor_status"] = f"corrected_drift_{drift}"

    return finding


# ---- driver --------------------------------------------------------------


def process_file(in_path: Path, out_path: Path, repo_root: Path) -> dict:
    data = json.loads(in_path.read_text())
    if "findings" not in data:
        return {"file": str(in_path), "error": "no findings field"}

    stats = {
        "file": str(in_path.name),
        "total": len(data["findings"]),
        "verified": 0,
        "verified_within_tolerance": 0,
        "corrected": 0,
        "no_anchor": 0,
        "file_missing": 0,
        "no_quoted_snippet": 0,
        "drifts": [],
    }
    for finding in data["findings"]:
        anchor_finding(finding, repo_root)
        status = finding.get("line_anchor_status", "?")
        if status == "verified":
            stats["verified"] += 1
        elif status.startswith("verified_within_tolerance"):
            stats["verified_within_tolerance"] += 1
        elif status.startswith("corrected"):
            stats["corrected"] += 1
            drift = int(status.split("_")[-1])
            stats["drifts"].append(drift)
        elif status == "no_anchor":
            stats["no_anchor"] += 1
        elif status == "file_missing":
            stats["file_missing"] += 1
        elif status == "no_quoted_snippet":
            stats["no_quoted_snippet"] += 1

    out_path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return stats


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="repo root for resolving finding.file")
    ap.add_argument("--in", dest="in_path", help="single peer JSON to process")
    ap.add_argument("--out", help="output path (default: <in>.anchored)")
    ap.add_argument(
        "--run-dir",
        help="process all {claude,codex,antigravity}.json in this directory in place",
    )
    args = ap.parse_args()

    repo_root = Path(args.repo).resolve()
    if not repo_root.is_dir():
        print(f"repo not found: {repo_root}", file=sys.stderr)
        return 2

    if args.run_dir:
        run_dir = Path(args.run_dir)
        results = []
        for name in ("claude.json", "codex.json", "antigravity.json"):
            p = run_dir / name
            if p.is_file():
                stats = process_file(p, p, repo_root)
                results.append(stats)
        # print summary
        print(json.dumps({"results": results}, indent=2))
        return 0

    if not args.in_path:
        print("either --in or --run-dir required", file=sys.stderr)
        return 2

    in_path = Path(args.in_path)
    out_path = Path(args.out) if args.out else in_path.with_suffix(".anchored.json")
    stats = process_file(in_path, out_path, repo_root)
    print(json.dumps(stats, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
