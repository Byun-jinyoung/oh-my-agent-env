#!/usr/bin/env python3
"""
Phase 6c — Per-module code-flow HTML renderer.

Reads module summaries from extract_module_flow.py and emits one HTML file per
module under .claude/codebase-scan/modules/html/{dir,community}/<slug>.html.

Design (per codex spec round-1 feedback):
  - Tables-first; mermaid graph is optional (--mermaid {cdn,off})
  - Caps to avoid unreadable graphs: node_cap, edge_cap
  - Distinguishes module categories: production / entrypoint / test / community
  - Module description comes from <repo>/<name>/__init__.py docstring when present
"""
from __future__ import annotations

import argparse
import ast
import html
import json
import sys
from pathlib import Path


def _esc(s: str) -> str:
    return html.escape(str(s))


def module_category(name: str) -> str:
    if name.startswith("C"):
        return "community"
    if name == "scripts":
        return "entrypoint"
    if name == "tests":
        return "test"
    return "production"


def module_docstring(repo: Path, name: str) -> str:
    """Module description: prefer __init__.py docstring, fall back to README first paragraph."""
    if name.startswith("C") or name in ("scripts", "tests", "other"):
        return ""
    # 1. __init__.py docstring
    init = repo / name / "__init__.py"
    if not init.exists():
        single = repo / f"{name}.py"
        if single.exists():
            init = single
    if init.exists():
        try:
            tree = ast.parse(init.read_text(encoding="utf-8", errors="replace"))
            doc = (ast.get_docstring(tree, clean=True) or "").strip().split("\n\n")[0]
            if doc:
                return doc
        except SyntaxError:
            pass
    # 2. README fallback (first paragraph)
    for readme in (repo / name / "README.md", repo / name / "README.rst"):
        if readme.exists():
            text = readme.read_text(encoding="utf-8", errors="replace")
            # skip leading heading lines (#, ===, ---) until first prose paragraph
            for para in text.split("\n\n"):
                cleaned = "\n".join(
                    ln for ln in para.splitlines()
                    if ln.strip() and not ln.lstrip().startswith("#")
                ).strip()
                if cleaned and not set(cleaned).issubset({"=", "-"}):
                    return cleaned[:400]
    return ""


CATEGORY_COLORS = {
    "production": "#2563eb",
    "entrypoint": "#d97706",
    "test": "#16a34a",
    "community": "#7c3aed",
}


CSS = """
:root { color-scheme: light dark; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
       margin: 1.5rem; max-width: 1100px; line-height: 1.5; }
h1 { margin-bottom: 0.25rem; }
.cat { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 4px;
       color: white; font-size: 0.8rem; vertical-align: middle; }
.desc { color: #555; margin-top: 0.25rem; font-style: italic; }
.stats { display: flex; gap: 1rem; flex-wrap: wrap; margin: 1rem 0; }
.stat { background: #f3f4f6; padding: 0.5rem 0.75rem; border-radius: 6px; font-size: 0.9rem; }
.stat b { color: #111; }
table { border-collapse: collapse; width: 100%; margin: 0.5rem 0 1.5rem; font-size: 0.88rem; }
th, td { border: 1px solid #e5e7eb; padding: 0.4rem 0.6rem; text-align: left; }
th { background: #f9fafb; }
code { font-family: 'SF Mono', Menlo, monospace; font-size: 0.85em; }
.bidi { color: #dc2626; font-weight: bold; }
details { margin: 0.5rem 0; }
details summary { cursor: pointer; padding: 0.3rem; background: #f3f4f6; border-radius: 4px; }
.mermaid-container { background: white; border: 1px solid #e5e7eb;
                     border-radius: 6px; padding: 0.5rem; min-height: 120px; }
@media (prefers-color-scheme: dark) {
  body { background: #1f2937; color: #f3f4f6; }
  .stat { background: #374151; }
  th { background: #374151; }
  td, th { border-color: #4b5563; }
  .desc { color: #d1d5db; }
  details summary { background: #374151; }
  .mermaid-container { background: #f9fafb; }
}
"""


def build_mermaid(summary: dict, node_cap: int = 25, edge_cap: int = 40) -> str:
    """Build a small mermaid flowchart from intra-call edges."""
    edges = summary.get("intra_call_edges", [])[:edge_cap]
    if not edges:
        return ""
    used: set[str] = set()
    lines = ["flowchart LR"]
    for e in edges:
        src, tgt, rel = e["src"], e["tgt"], e["relation"]
        used.add(src); used.add(tgt)
        if len(used) > node_cap:
            break
        arrow = "-.->|method|" if rel == "method" else ("---|contains|" if rel == "contains" else "-->|calls|")
        # mermaid id-safe: replace : / . with _
        s_id = src.replace(":", "_").replace(".", "_").replace("-", "_")
        t_id = tgt.replace(":", "_").replace(".", "_").replace("-", "_")
        lines.append(f"  {s_id}[\"{src.rsplit('_', 2)[-1]}\"] {arrow} {t_id}[\"{tgt.rsplit('_', 2)[-1]}\"]")
    return "\n".join(lines)


def render_html(summary: dict, description: str, mermaid_mode: str) -> str:
    name = summary["name"]
    cat = module_category(name)
    color = CATEGORY_COLORS[cat]

    rels = summary.get("internal_edge_counts_by_relation", {})
    inbound = summary.get("inbound_top_sources", [])
    outbound = summary.get("outbound_top_targets", [])
    bidir = {f for f, _ in inbound} & {f for f, _ in outbound}

    parts: list[str] = []
    parts.append("<!doctype html><html><head><meta charset='utf-8'>")
    parts.append(f"<title>{_esc(name)} — code flow</title>")
    parts.append(f"<style>{CSS}</style>")
    if mermaid_mode == "cdn":
        parts.append(
            "<script type='module'>"
            "import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs';"
            "mermaid.initialize({startOnLoad: true, theme: 'default'});"
            "</script>"
        )
    elif mermaid_mode == "vendor":
        # vendored relative path; publisher copies vendor/ into vault html dir
        parts.append("<script src='../../vendor/mermaid.min.js'></script>")
        parts.append("<script>mermaid.initialize({startOnLoad: true, theme: 'default'});</script>")
    parts.append("</head><body>")

    parts.append(f"<h1>{_esc(name)} <span class='cat' style='background:{color}'>{cat}</span></h1>")
    if description:
        parts.append(f"<div class='desc'>{_esc(description)}</div>")

    parts.append("<div class='stats'>")
    parts.append(f"<div class='stat'><b>{summary['n_files']}</b> files</div>")
    parts.append(f"<div class='stat'><b>{summary['n_functions']}</b> functions/classes</div>")
    parts.append(f"<div class='stat'><b>{summary['n_internal_edges']}</b> internal edges</div>")
    parts.append(f"<div class='stat'><b>{summary['n_outbound_edges']}</b> outbound</div>")
    parts.append(f"<div class='stat'><b>{summary['n_inbound_edges']}</b> inbound</div>")
    if bidir:
        parts.append(f"<div class='stat bidi'>⇄ {len(bidir)} bidir modules</div>")
    parts.append("</div>")

    # Relation breakdown
    if rels:
        parts.append("<h2>Internal edge relations</h2><table><tr><th>relation</th><th>count</th></tr>")
        for r, c in sorted(rels.items(), key=lambda kv: -kv[1]):
            parts.append(f"<tr><td><code>{_esc(r)}</code></td><td>{c}</td></tr>")
        parts.append("</table>")

    # Files
    files = summary.get("files", [])[:40]
    if files:
        parts.append(f"<h2>Files ({len(files)})</h2><ul>")
        for f in files:
            parts.append(f"<li><code>{_esc(f)}</code></li>")
        parts.append("</ul>")

    # Functions
    funcs = summary.get("functions", [])[:60]
    if funcs:
        parts.append(f"<h2>Functions / classes (showing {len(funcs)})</h2>")
        parts.append("<table><tr><th>label</th><th>source</th></tr>")
        for fn in funcs:
            sf = fn.get("source_file", "?")
            sl = fn.get("source_location", "")
            loc = f"{sf}:{sl[1:]}" if sl.startswith("L") and sl[1:].isdigit() else sf
            parts.append(f"<tr><td><code>{_esc(fn.get('label') or '?')}</code></td><td><code>{_esc(loc)}</code></td></tr>")
        parts.append("</table>")

    # Inbound / Outbound — split by relation (imports vs calls vs inherits ...)
    def _render_split(title: str, total: int, split: dict, col_side: str):
        if not split.get("by_relation_top_files"):
            return
        counts = split.get("by_relation_counts", {})
        parts.append(f"<h2>{title} ({total} edges total)</h2>")
        # summary chip line
        chip = "  ·  ".join(f"<b>{k}</b>: {v}" for k, v in sorted(counts.items(), key=lambda kv: -kv[1]))
        parts.append(f"<div class='desc'>{chip}</div>")
        for rel, rows in split["by_relation_top_files"].items():
            parts.append(f"<details><summary><b>{_esc(rel)}</b> — top {len(rows)} {col_side} files (count {counts.get(rel,0)})</summary>")
            parts.append(f"<table><tr><th>{col_side} file</th><th>edges</th><th>bidir?</th></tr>")
            for f, c in rows:
                mark = "⇄" if f in bidir else ""
                parts.append(f"<tr><td><code>{_esc(f)}</code></td><td>{c}</td><td class='bidi'>{mark}</td></tr>")
            parts.append("</table></details>")

    _render_split(
        "Outbound public-API (this module → other)",
        summary["n_outbound_edges"],
        summary.get("outbound_by_relation", {}),
        "target",
    )
    _render_split(
        "Inbound dependents (other → this module)",
        summary["n_inbound_edges"],
        summary.get("inbound_by_relation", {}),
        "source",
    )

    # Mermaid graph
    if mermaid_mode in ("cdn", "vendor"):
        mer = build_mermaid(summary)
        if mer:
            parts.append("<h2>Intra-module call graph (capped)</h2>")
            parts.append(f"<div class='mermaid-container'><pre class='mermaid'>{_esc(mer)}</pre></div>")
            parts.append("<details><summary>raw mermaid source</summary>")
            parts.append(f"<pre>{_esc(mer)}</pre></details>")

    parts.append("</body></html>")
    return "\n".join(parts)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("repo", type=Path)
    p.add_argument("--in", dest="in_dir", type=Path, default=None,
                   help="input dir from extract_module_flow.py "
                        "(default <repo>/.claude/codebase-scan/modules)")
    p.add_argument("--out", type=Path, default=None,
                   help="output html dir (default <in>/html)")
    p.add_argument("--mermaid", choices=("cdn", "vendor", "off"), default="vendor",
                   help="cdn = jsdelivr, vendor = local mermaid.min.js (default, self-contained), off = tables only")
    args = p.parse_args()

    repo = args.repo.resolve()
    in_dir = args.in_dir or (repo / ".claude" / "codebase-scan" / "modules")
    out_dir = args.out or (in_dir / "html")
    if not in_dir.exists():
        print(f"[err] no modules dir at {in_dir}", file=sys.stderr)
        return 2

    (out_dir / "dir").mkdir(parents=True, exist_ok=True)
    (out_dir / "community").mkdir(parents=True, exist_ok=True)

    count = 0
    for sub in ("dir", "community"):
        for jf in sorted((in_dir / sub).glob("*.json")):
            try:
                s = json.loads(jf.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                continue
            desc = module_docstring(repo, s["name"])
            html_text = render_html(s, desc, args.mermaid)
            (out_dir / sub / f"{jf.stem}.html").write_text(html_text, encoding="utf-8")
            count += 1

    print(f"[ok] rendered {count} module HTML pages → {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
