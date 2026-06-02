#!/usr/bin/env python3
"""
Phase 2.5 — Data flow & type extractor.

Walks Python files (selected from L1 blast top-N + entry points + src/ fallback),
extracts function signatures, return types, dataclass/pydantic/TypedDict/NamedTuple
fields, torch.nn.Module.forward signatures, and tensor-shape annotation comments.

Outputs (defaults; override with --out):
  .claude/codebase-scan/dataflow/functions.json   structured data
  .claude/codebase-scan/dataflow/dataflow.md      human-readable table
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Tensor shape comment: `# (B, N, D)` style. Require ≥ 1 comma and tokens
# limited to dim names (letters/_, optional ? or *) or pure integers. This
# avoids matching prose comments like `# (TODO)` or `# (i.e. ...)`, while still
# allowing `# (B, N, 3)` or `# (B*N, 512, ?)`.
_SHAPE_DIM = r"(?:[A-Za-z_][\w?*]*|\d+)"
SHAPE_RE = re.compile(
    rf"#\s*\(\s*({_SHAPE_DIM}(?:\s*,\s*{_SHAPE_DIM})+)\s*\)"
)
DATACLASS_DECOS = {"dataclass", "dataclasses.dataclass", "pydantic.dataclass"}
PYDANTIC_BASES = {"BaseModel", "pydantic.BaseModel"}
TYPED_BASES = {"TypedDict", "typing.TypedDict", "NamedTuple", "typing.NamedTuple"}


def _ann(node: ast.AST | None) -> str:
    if node is None:
        return ""
    try:
        return ast.unparse(node)
    except Exception:
        return "<unparse-fail>"


def _deco_names(node: ast.AST) -> set[str]:
    names: set[str] = set()
    for d in getattr(node, "decorator_list", []):
        if isinstance(d, ast.Name):
            names.add(d.id)
        elif isinstance(d, ast.Attribute):
            names.add(_ann(d))
        elif isinstance(d, ast.Call):
            names.add(_ann(d.func))
    return names


def _base_names(cls: ast.ClassDef) -> set[str]:
    names: set[str] = set()
    for b in cls.bases:
        names.add(_ann(b))
    return names


def _docstring_first_line(node: ast.AST) -> str:
    d = ast.get_docstring(node, clean=True) or ""
    return d.split("\n", 1)[0].strip()[:200]


@dataclass
class FuncInfo:
    file: str
    name: str
    qualname: str
    kind: str  # "function" | "method" | "forward"
    params: list[dict] = field(default_factory=list)
    returns: str = ""
    docstring: str = ""
    calls: list[str] = field(default_factory=list)
    line: int = 0


@dataclass
class DataClassInfo:
    file: str
    name: str
    kind: str  # "dataclass" | "pydantic" | "typeddict" | "namedtuple" | "torch_module"
    fields: list[dict] = field(default_factory=list)
    line: int = 0


def _classify_class(cls: ast.ClassDef) -> str | None:
    decos = _deco_names(cls)
    bases = _base_names(cls)
    if decos & DATACLASS_DECOS:
        return "dataclass"
    if bases & PYDANTIC_BASES or any("BaseModel" in b for b in bases):
        return "pydantic"
    if any(b in TYPED_BASES or "TypedDict" in b for b in bases):
        return "typeddict"
    if any("NamedTuple" in b for b in bases):
        return "namedtuple"
    if any("nn.Module" in b or b.endswith("Module") for b in bases):
        return "torch_module"
    return None


def _extract_fields(cls: ast.ClassDef) -> list[dict]:
    out = []
    for stmt in cls.body:
        if isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name):
            out.append({"name": stmt.target.id, "type": _ann(stmt.annotation)})
    return out


def _extract_calls(fn: ast.AST, limit: int = 12) -> list[str]:
    calls: list[str] = []
    for node in ast.walk(fn):
        if isinstance(node, ast.Call):
            name = _ann(node.func)
            if name and name not in calls:
                calls.append(name)
                if len(calls) >= limit:
                    break
    return calls


def _find_shape_comments(source: str, start: int, end: int) -> list[str]:
    lines = source.splitlines()[start - 1 : end]
    shapes = []
    for ln in lines:
        m = SHAPE_RE.search(ln)
        if m:
            shapes.append(m.group(1).strip())
    return shapes


def analyze_file(path: Path, repo_root: Path) -> tuple[list[FuncInfo], list[DataClassInfo]]:
    try:
        src = path.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(src, filename=str(path))
    except SyntaxError:
        return [], []
    rel = str(path.relative_to(repo_root))
    funcs: list[FuncInfo] = []
    classes: list[DataClassInfo] = []

    class V(ast.NodeVisitor):
        def __init__(self):
            self.stack: list[str] = []
            # class kind only (None for nested-fn scopes), used to tell whether
            # the immediate enclosing scope is a class — and which kind.
            self.class_kind_stack: list[str | None] = []

        def visit_ClassDef(self, node: ast.ClassDef):
            kind = _classify_class(node)
            if kind:
                classes.append(
                    DataClassInfo(
                        file=rel,
                        name=node.name,
                        kind=kind,
                        fields=_extract_fields(node),
                        line=node.lineno,
                    )
                )
            self.stack.append(node.name)
            self.class_kind_stack.append(kind)
            self.generic_visit(node)
            self.class_kind_stack.pop()
            self.stack.pop()

        def _add_fn(self, node: ast.FunctionDef | ast.AsyncFunctionDef):
            params = []
            for a in node.args.args:
                params.append({"name": a.arg, "type": _ann(a.annotation)})
            if node.args.kwonlyargs:
                for a in node.args.kwonlyargs:
                    params.append({"name": a.arg, "type": _ann(a.annotation), "kwonly": True})
            qual = ".".join([*self.stack, node.name])
            parent_class_kind = self.class_kind_stack[-1] if self.class_kind_stack else None
            if parent_class_kind is None:
                kind = "function"
            elif node.name == "forward" and parent_class_kind == "torch_module":
                kind = "forward"
            else:
                kind = "method"
            end = getattr(node, "end_lineno", None) or node.lineno
            shapes = _find_shape_comments(src, node.lineno, end)
            doc = _docstring_first_line(node)
            if shapes:
                doc = (doc + f"  [shapes: {'; '.join(shapes[:4])}]").strip()
            funcs.append(
                FuncInfo(
                    file=rel,
                    name=node.name,
                    qualname=qual,
                    kind=kind,
                    params=params,
                    returns=_ann(node.returns),
                    docstring=doc,
                    calls=_extract_calls(node),
                    line=node.lineno,
                )
            )

        def visit_FunctionDef(self, node):
            self._add_fn(node)
            self.stack.append(node.name)
            self.generic_visit(node)
            self.stack.pop()

        def visit_AsyncFunctionDef(self, node):
            self._add_fn(node)
            self.stack.append(node.name)
            self.generic_visit(node)
            self.stack.pop()

    V().visit(tree)
    return funcs, classes


def pick_files(repo: Path, evidence: Path | None, top_n: int) -> list[Path]:
    files: list[Path] = []
    if evidence and evidence.exists():
        try:
            data = json.loads(evidence.read_text())
            # support both {"blast": [...]} and L1.json formats
            blast = data.get("blast") or data.get("hubs") or []
            for entry in blast[:top_n]:
                if isinstance(entry, dict):
                    # CRG L1.json blast uses `file_path` (see extract_l1.py).
                    # Older variants / generic hubs may use file/path/name.
                    p = (entry.get("file_path") or entry.get("file")
                         or entry.get("path") or entry.get("name"))
                else:
                    p = entry
                if p:
                    fp = repo / p if not Path(p).is_absolute() else Path(p)
                    if fp.exists() and fp.suffix == ".py":
                        files.append(fp)
        except Exception as e:
            print(f"[warn] failed to parse evidence: {e}", file=sys.stderr)

    if not files:
        # Fallback: prefer src/**/*.py, but only if src/ actually contains .py.
        # Otherwise fall through to repo-wide scan — important for flat layouts
        # (e.g. ADFLIP has top-level model/, data/, PIPPack/ and a src/ with
        # only bash scripts).
        src_dir = repo / "src"
        if src_dir.exists():
            files.extend(sorted(src_dir.rglob("*.py")))
        if not files:
            files.extend(sorted(repo.rglob("*.py")))

    # dedup + filter vendored/test files for primary table
    seen, out = set(), []
    for f in files:
        if f in seen:
            continue
        seen.add(f)
        parts = set(f.parts)
        if parts & {".venv", "venv", "env", ".env",
                     "__pycache__", "site-packages",
                     "node_modules", ".tox", ".pytest_cache",
                     ".eggs", "build", "dist"}:
            continue
        out.append(f)
    return out[:top_n] if evidence else out


def write_outputs(out_dir: Path, funcs: list[FuncInfo], classes: list[DataClassInfo]) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "functions": [f.__dict__ for f in funcs],
        "data_classes": [c.__dict__ for c in classes],
        "n_functions": len(funcs),
        "n_classes": len(classes),
    }
    (out_dir / "functions.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False))

    lines: list[str] = ["# Data Flow & Types\n"]
    if classes:
        lines.append("## Data Structures\n")
        lines.append("| File | Name | Kind | Fields |")
        lines.append("|---|---|---|---|")
        for c in classes:
            f_repr = "; ".join(f"`{x['name']}: {x['type'] or '?'}`" for x in c.fields[:8])
            lines.append(f"| `{c.file}:{c.line}` | `{c.name}` | {c.kind} | {f_repr or '—'} |")
        lines.append("")

    if funcs:
        lines.append("## Functions / Methods (signatures)\n")
        lines.append("| File | Qualname | Kind | Params (name: type) | Returns | Doc / Shapes |")
        lines.append("|---|---|---|---|---|---|")
        for fn in funcs:
            params = ", ".join(f"{p['name']}: {p.get('type') or '?'}" for p in fn.params)
            lines.append(
                f"| `{fn.file}:{fn.line}` | `{fn.qualname}` | {fn.kind} | "
                f"{params or '—'} | `{fn.returns or '—'}` | {fn.docstring or '—'} |"
            )

    (out_dir / "dataflow.md").write_text("\n".join(lines))


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("repo", type=Path)
    p.add_argument("--evidence", type=Path, default=None,
                   help="L1.json path (defaults to <repo>/.codemap/evidence/L1.json)")
    p.add_argument("--top", type=int, default=15)
    p.add_argument("--out", type=Path, default=None,
                   help="output dir (defaults to <repo>/.codemap/dataflow)")
    args = p.parse_args()

    repo = args.repo.resolve()
    if not repo.is_dir():
        print(f"[err] not a directory: {repo}", file=sys.stderr)
        return 2

    evidence = args.evidence or (repo / ".claude" / "codebase-scan" / "evidence" / "L1.json")
    out_dir = args.out or (repo / ".claude" / "codebase-scan" / "dataflow")

    files = pick_files(repo, evidence if evidence.exists() else None, args.top)
    if not files:
        print("[err] no Python files found", file=sys.stderr)
        return 1

    print(f"[info] analyzing {len(files)} files")
    all_funcs: list[FuncInfo] = []
    all_classes: list[DataClassInfo] = []
    for fp in files:
        fns, cls = analyze_file(fp, repo)
        all_funcs.extend(fns)
        all_classes.extend(cls)

    write_outputs(out_dir, all_funcs, all_classes)
    print(f"[ok] wrote {len(all_funcs)} functions, {len(all_classes)} classes to {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
