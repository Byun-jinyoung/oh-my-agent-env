#!/usr/bin/env python3
"""
Phase 6b — Publish .codemap artifacts to an Obsidian vault as wikilinked notes.

Default destination: <vault>/Research/{proj}/codemap/
Files written:
  index.md          entry-point, wikilinks to siblings + frontmatter
  architecture.md   copy of CODEBASE-MAP.md (sanitized) + back-links
  dataflow.md       copy of .codemap/dataflow/dataflow.md
  facts.md          copy of .codemap/evidence/L1-facts.md
  consensus.md      copy of .codemap/consensus/hubs-consensus.md (if present)
  html-report.md    relative path links to graphify HTML

All notes get frontmatter:
  tags: [codemap, <proj>]
  source_repo: <abs path>
  generated_at: <iso>
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import shutil
import sys
from pathlib import Path


# ─── codegraph live-query integration ──────────────────────────────────────
# Detected once per run; templated suggestions appended to each markdown so a
# session reader can drop into MCP/CLI for deeper lookups without re-scanning.

def codegraph_available() -> bool:
    """True if codegraph CLI is on PATH or MCP server is registered."""
    if shutil.which("codegraph"):
        return True
    claude_json = Path.home() / ".claude.json"
    if claude_json.exists():
        try:
            cfg = json.loads(claude_json.read_text(encoding="utf-8"))
            return "codegraph" in (cfg.get("mcpServers") or {})
        except (json.JSONDecodeError, OSError):
            return False
    return False


_CODEGRAPH_HEADER = (
    "\n\n## 🔎 Live query (codegraph)\n\n"
    "_codemap은 정적 top-N 산출물. 더 깊은 탐색은 codegraph로._\n\n"
    "**MCP 도구** (Claude Code 세션 내 사용; 정확한 ID는 환경에 따라 "
    "`mcp__codegraph__codegraph_*` — Claude Code 환경 기준 검증됨):\n"
    "- `mcp__codegraph__codegraph_context` — PRIMARY. task 설명 1개로 entry points + callers + callees + 코드 스니펫 통합 반환\n"
    "- `mcp__codegraph__codegraph_search` — 심볼 이름 빠른 검색 (위치만)\n"
    "- `mcp__codegraph__codegraph_callers` / `mcp__codegraph__codegraph_callees` — 호출자/피호출자\n"
    "- `mcp__codegraph__codegraph_impact` — 변경 시 blast radius (depth 인자 지원)\n"
    "- `mcp__codegraph__codegraph_node` / `mcp__codegraph__codegraph_explore` — 단일/다수 심볼 소스\n"
    "- `mcp__codegraph__codegraph_files` / `mcp__codegraph__codegraph_status` — 파일트리/인덱스 상태\n\n"
    "**검색 팁** (if-dfm 실측 기반):\n"
    "- 클래스 이름(`BD3LMDynamics`)으로는 caller가 거의 안 잡힘 — 메서드명(`corrupt`, `sample`)으로 검색하라.\n"
    "- `codegraph_callers`는 직접 호출만 잡고 동적 dispatch(`dyn.corrupt()`)는 놓침. 광범위 영향은 `codegraph_impact` 우선.\n"
    "- 동명이인 심볼은 자동 aggregation됨 (응답 하단 Note에 분리 표시).\n\n"
    "**CLI** (셸 명령, 검증됨):\n\n"
)


def codegraph_footer(page_type: str, repo: Path) -> str:
    """Page-type-aware codegraph command suggestions. Empty if not available."""
    if not codegraph_available():
        return ""
    cd = f"cd {repo}"
    suggestions: list[tuple[str, str]] = []
    if page_type == "index":
        suggestions = [
            ("repo 전반 검색", 'codegraph query "<symbol-or-keyword>"'),
            ("파일 트리", "codegraph files"),
            ("작업 컨텍스트 빌드 (권장)", 'codegraph context "implement feature X"'),
            ("인덱스 상태", "codegraph status"),
        ]
    elif page_type == "architecture":
        suggestions = [
            ("심볼 정의 찾기", 'codegraph query "<ClassName>"'),
            ("컨텍스트 통합 (MCP 권장)",
             '# MCP: mcp__codegraph__codegraph_context task="how does X work"'),
            ("관련 파일 묶음", "codegraph files"),
        ]
    elif page_type == "dataflow":
        suggestions = [
            ("함수 정의 + 시그니처", 'codegraph query "<func>"'),
            ("함수 callers (MCP)",
             '# MCP: mcp__codegraph__codegraph_callers symbol="<func>"'),
            ("함수 callees (MCP)",
             '# MCP: mcp__codegraph__codegraph_callees symbol="<func>"'),
        ]
    elif page_type == "call-chain":
        suggestions = [
            ("anchor의 callers (MCP)",
             '# MCP: mcp__codegraph__codegraph_callers symbol="<anchor>"'),
            ("anchor의 callees (MCP)",
             '# MCP: mcp__codegraph__codegraph_callees symbol="<anchor>"'),
            ("anchor 영향 분석 — depth 인자는 impact만 지원",
             '# MCP: mcp__codegraph__codegraph_impact symbol="<anchor>" depth=2'),
        ]
    elif page_type == "coverage":
        suggestions = [
            ("변경된 파일이 영향 주는 테스트", "codegraph affected <changed_file>.py"),
            ("심볼 변경 blast radius (MCP)",
             '# MCP: mcp__codegraph__codegraph_impact symbol="<func>" depth=2'),
            ("관련 production+test 파일", 'codegraph query "<feature>"'),
        ]
    elif page_type.startswith("module"):
        suggestions = [
            ("이 모듈 심볼 검색", 'codegraph query "<symbol-in-module>"'),
            ("모듈 컨텍스트 통합", 'codegraph context "describe <module>"'),
            ("모듈 함수의 호출자 (MCP)",
             '# MCP: mcp__codegraph__codegraph_callers symbol="<func>"'),
        ]
    else:
        return ""

    lines = [_CODEGRAPH_HEADER, "```bash", cd]
    for label, cmd in suggestions:
        lines.append(f"# {label}")
        lines.append(cmd)
    lines.append("```")
    lines.append("\n_실측 검증 (if-dfm pilot)_: CLI `codegraph query/context/status` + "
                 "MCP `codegraph_status/search/callers/impact (depth=2)`. "
                 "impact는 corrupt 1심볼 → 65 영향 심볼 정상 반환. callers는 동적 dispatch 미감지 한계 있음.")
    return "\n".join(lines)


FRONTMATTER_TMPL = """---
tags: [codemap, {proj}]
source_repo: {repo}
generated_at: {ts}
note_type: {note_type}
---

"""


def _fm(proj: str, repo: str, note_type: str) -> str:
    return FRONTMATTER_TMPL.format(
        proj=proj,
        repo=repo,
        ts=_dt.datetime.now().isoformat(timespec="seconds"),
        note_type=note_type,
    )


def _copy_with_fm(src: Path, dst: Path, proj: str, repo: str, note_type: str) -> bool:
    if not src.exists():
        return False
    body = src.read_text(encoding="utf-8")
    footer = codegraph_footer(note_type, Path(repo))
    dst.write_text(_fm(proj, repo, note_type) + body + footer, encoding="utf-8")
    return True


def write_index(dst_dir: Path, proj: str, repo: Path, written: dict[str, bool], html_rel: str | None) -> None:
    links = []
    if written.get("architecture"):
        links.append("- 🏛 [[architecture]] — repo의 큰 그림, audit된 narrative")
    if written.get("dataflow"):
        links.append("- 🔀 [[dataflow]] — 함수 signature / I/O type / dataclass")
    if written.get("call_chain"):
        links.append("- ⛓ [[call-chain]] — top callee의 caller/callee 1-hop 표")
    if written.get("coverage"):
        links.append("- 🧪 [[coverage]] — production 심볼 ↔ test 매핑 (CRG TESTED_BY)")
    if written.get("facts"):
        links.append("- 📊 [[facts]] — CRG L1 수치 증거 (BLAST/HUB/INHERIT/COMM)")
    if written.get("consensus"):
        links.append("- 🤝 [[consensus]] — 다중 도구 hub 합의 / DEBATE 항목")
    if written.get("html"):
        links.append("- 🌐 [[html-report]] — graphify 인터랙티브 그래프")

    # Per-module wikilinks (dir + community)
    module_links: list[str] = []
    modules_md = dst_dir / "modules"
    for sub in ("dir", "community"):
        sub_dir = modules_md / sub
        if not sub_dir.exists():
            continue
        title = "📦 디렉토리 모듈" if sub == "dir" else "🧩 community 모듈"
        items = sorted(sub_dir.glob("*.md"))
        if not items:
            continue
        module_links.append("")
        module_links.append(f"### {title}")
        for m in items:
            module_links.append(f"- [[modules/{sub}/{m.stem}|{m.stem}]]")

    body = [
        f"# {proj} — Code Map",
        "",
        "> codebase-scan으로 생성된 영구 분석 문서. 다음 세션에서 이 파일을 먼저 읽고 시작하세요.",
        "",
        f"**Source repo**: `{repo}`",
        "",
        "## 빠른 진입",
        "",
        *links,
        "",
        "## 모듈별 code-flow (SRP 단위)",
        *module_links,
        "",
        "## 사용 가이드",
        "",
        "1. **새 세션 시작 시**: 이 `index.md` → `[[architecture]]` → 작업과 관련된 `[[dataflow]]` 섹션 순으로 읽기",
        "2. **특정 모듈 작업 시**: `## 모듈별 code-flow` 섹션의 해당 wikilink → iframe HTML로 모듈 내부 흐름 확인",
        "3. **호출 추적**: `[[call-chain]]`에서 top callee의 caller/callee 1-hop 표 확인",
        "4. **수정 후**: `code-review-graph build --repo .` 재실행 → 이 디렉토리 재발행",
        "5. **신뢰도**: `[[facts]]`는 결정적, `[[architecture]]`는 audited prose, `[[consensus]]`는 N개 도구 합의 기반",
    ]
    (dst_dir / "index.md").write_text(
        _fm(proj, str(repo), "index") + "\n".join(body) + codegraph_footer("index", repo),
        encoding="utf-8",
    )


def copy_mermaid_vendor(dst_html_root: Path) -> bool:
    """Copy vendored mermaid.min.js next to module HTML pages."""
    src = Path(__file__).resolve().parent.parent / "vendor" / "mermaid.min.js"
    if not src.exists():
        return False
    vendor_dst = dst_html_root / "vendor"
    vendor_dst.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, vendor_dst / "mermaid.min.js")
    return True


def publish_modules(
    codemap: Path, dst_dir: Path, proj: str, repo: Path
) -> dict[str, int]:
    """Copy module HTMLs into vault and emit per-module markdown stubs with iframes.

    Returns counts for index.md to summarize.
    """
    modules_root = codemap / "modules"
    html_root = modules_root / "html"
    if not modules_root.exists() or not html_root.exists():
        return {"dir": 0, "community": 0}

    vault_html = dst_dir / "html"
    vault_md = dst_dir / "modules"
    counts = {"dir": 0, "community": 0}
    # Self-contained: copy mermaid.min.js once for relative-path import
    copy_mermaid_vendor(vault_html)

    index_data = {}
    idx_path = modules_root / "index.json"
    if idx_path.exists():
        try:
            index_data = json.loads(idx_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            index_data = {}

    for sub in ("dir", "community"):
        src_html_dir = html_root / sub
        src_json_dir = modules_root / sub
        if not src_html_dir.exists():
            continue
        (vault_html / sub).mkdir(parents=True, exist_ok=True)
        (vault_md / sub).mkdir(parents=True, exist_ok=True)

        for html_file in sorted(src_html_dir.glob("*.html")):
            slug = html_file.stem
            # copy HTML so iframe can use a relative path (more portable than file:///)
            shutil.copy2(html_file, vault_html / sub / html_file.name)

            # short summary from JSON (if present)
            json_file = src_json_dir / f"{slug}.json"
            summary = {}
            if json_file.exists():
                try:
                    summary = json.loads(json_file.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    summary = {}

            name = summary.get("name", slug)
            n_files = summary.get("n_files", "?")
            n_funcs = summary.get("n_functions", "?")
            n_int = summary.get("n_internal_edges", "?")
            n_out = summary.get("n_outbound_edges", "?")
            n_in = summary.get("n_inbound_edges", "?")
            iframe_src = f"../html/{sub}/{html_file.name}"

            body = [
                f"# `{name}` — module code flow",
                "",
                f"- files: **{n_files}**  ·  functions/classes: **{n_funcs}**",
                f"- internal edges: **{n_int}**  ·  outbound: **{n_out}**  ·  inbound: **{n_in}**",
                "",
                "## 인터랙티브 HTML",
                "",
                f"<iframe src=\"{iframe_src}\" width=\"100%\" height=\"700\" style=\"border:1px solid #ccc;border-radius:6px\"></iframe>",
                "",
                "> Obsidian 환경에 따라 iframe이 sanitize될 수 있습니다. 그 경우 외부 브라우저로 열어주세요:",
                "> ```bash",
                f"> open \"{(vault_html / sub / html_file.name).resolve()}\"",
                "> ```",
                "",
                "## 관련 노트",
                "- [[index|← index]]",
                "- [[../architecture|architecture]]",
                "- [[../call-chain|call-chain]]",
            ]
            md_text = (
                _fm(proj, str(repo), f"module-{sub}")
                + "\n".join(body)
                + codegraph_footer(f"module-{sub}", repo)
            )
            (vault_md / sub / f"{slug}.md").write_text(md_text, encoding="utf-8")
            counts[sub] += 1

    return counts


def publish_call_chain(codemap: Path, dst_dir: Path, proj: str, repo: str) -> bool:
    src = codemap / "dataflow" / "call_chain.md"
    return _copy_with_fm(src, dst_dir / "call-chain.md", proj, repo, "call-chain")


def publish_coverage(codemap: Path, dst_dir: Path, proj: str, repo: str) -> bool:
    src = codemap / "coverage" / "coverage_map.md"
    return _copy_with_fm(src, dst_dir / "coverage.md", proj, repo, "coverage")


def write_html_report(dst_dir: Path, proj: str, repo: Path, html_rel: str) -> None:
    body = [
        f"# {proj} — graphify 인터랙티브 리포트",
        "",
        f"파일 경로: `{html_rel}`",
        "",
        "Obsidian에서는 외부 HTML을 직접 렌더링하지 않으므로 시스템 브라우저로 열어주세요:",
        "",
        f"```bash",
        f"open {html_rel}",
        f"```",
        "",
        "관련 노트:",
        "- [[index]]",
        "- [[architecture]]",
        "- [[consensus]]",
    ]
    (dst_dir / "html-report.md").write_text(_fm(proj, str(repo), "html-report") + "\n".join(body), encoding="utf-8")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("repo", type=Path, help="repo root (must contain .codemap/)")
    p.add_argument("--vault", type=Path, required=True, help="Obsidian vault root")
    p.add_argument("--proj", type=str, default=None, help="project slug (defaults to repo name)")
    p.add_argument("--subdir", type=str, default="Research",
                   help="vault subdir under which to write (default: Research)")
    p.add_argument("--force", action="store_true",
                   help="overwrite existing codemap dir without warning")
    args = p.parse_args()

    repo = args.repo.resolve()
    codemap = repo / ".claude" / "codebase-scan"
    if not codemap.is_dir():
        print(f"[err] no .claude/codebase-scan/ in {repo}", file=sys.stderr)
        return 2

    raw_proj = args.proj or repo.name
    # sanitize: only the leaf component, no path traversal
    proj = Path(raw_proj).name
    if not proj or proj in (".", ".."):
        print(f"[err] invalid --proj value: {raw_proj!r}", file=sys.stderr)
        return 2
    dst_dir = args.vault / args.subdir / proj / "codemap"
    if dst_dir.exists() and any(dst_dir.iterdir()) and not args.force:
        print(
            f"[warn] {dst_dir} already exists and is non-empty; "
            f"files will be overwritten. Pass --force to silence this warning.",
            file=sys.stderr,
        )
    dst_dir.mkdir(parents=True, exist_ok=True)

    written = {
        "architecture": _copy_with_fm(codemap / "CODEBASE-MAP.md", dst_dir / "architecture.md", proj, str(repo), "architecture"),
        "dataflow":     _copy_with_fm(codemap / "dataflow" / "dataflow.md", dst_dir / "dataflow.md", proj, str(repo), "dataflow"),
        "facts":        _copy_with_fm(codemap / "evidence" / "L1-facts.md", dst_dir / "facts.md", proj, str(repo), "facts"),
        "consensus":    _copy_with_fm(codemap / "consensus" / "hubs-consensus.md", dst_dir / "consensus.md", proj, str(repo), "consensus"),
        "call_chain":   publish_call_chain(codemap, dst_dir, proj, str(repo)),
        "coverage":     publish_coverage(codemap, dst_dir, proj, str(repo)),
    }
    module_counts = publish_modules(codemap, dst_dir, proj, repo)
    written["modules_dir"] = module_counts.get("dir", 0) > 0
    written["modules_community"] = module_counts.get("community", 0) > 0

    # graphify writes graph.html (file-graph build) or index.html (full wiki build)
    html_candidates = [
        repo / "graphify-out" / "graph.html",
        repo / "graphify-out" / "index.html",
        codemap / "graphify-out" / "graph.html",
        codemap / "graphify-out" / "index.html",
    ]
    html_rel = None
    for cand in html_candidates:
        if cand.exists():
            html_rel = str(cand)
            write_html_report(dst_dir, proj, repo, html_rel)
            written["html"] = True
            break

    write_index(dst_dir, proj, repo, written, html_rel)

    # Per-page source/phase hints for clearer SKIP messages.
    skip_hints = {
        "architecture":      f"{codemap / 'CODEBASE-MAP.md'} — requires Phase 5 (LLM narrative; not auto-generated by any script)",
        "dataflow":          f"{codemap / 'dataflow' / 'dataflow.md'} — run Phase 2.5 extract_dataflow.py",
        "facts":             f"{codemap / 'evidence' / 'L1-facts.md'} — run Phase 1 CRG L1 extract",
        "consensus":         f"{codemap / 'consensus' / 'hubs-consensus.md'} — run Phase 4.5 consensus_hubs.py",
        "call_chain":        f"{codemap / 'dataflow' / 'call_chain.md'} — run Phase 2.7 extract_call_chain.py",
        "coverage":          f"{codemap / 'coverage' / 'coverage_map.md'} — run Phase 2.8 extract_test_coverage.py",
        "modules_dir":       f"{codemap / 'modules' / 'dir'}/*.json — run Phase 2.6 extract_module_flow.py",
        "modules_community": f"{codemap / 'modules' / 'community'}/*.json — run Phase 2.6 extract_module_flow.py",
        "html":              f"{repo / 'graphify-out' / 'graph.html'} — run `graphify update {repo}` first",
    }
    print(f"[ok] published to {dst_dir}")
    for k, v in written.items():
        if v:
            print(f"  - {k}: OK")
        else:
            print(f"  - {k}: SKIP ({skip_hints.get(k, 'source missing')})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
