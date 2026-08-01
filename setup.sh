#!/bin/bash
# oh-my-agent-env: AI development environment bootstrap
# Usage:
#   git clone https://github.com/Byun-jinyoung/oh-my-agent-env.git ~/.oh-my-agent-env
#   cd ~/.oh-my-agent-env && ./setup.sh sync
#
# Subcommands:
#   sync      — Create/update symlinks from runtime dirs to this repo
#   doctor    — Check dependencies (system packages, Python libs, CLIs)
#   validate  — Validate skill frontmatter
#   update    — git pull → validate → sync → doctor
#   install   — Legacy copy-based install (environments where symlinks don't work)
#   init-project <path> — Initialize per-project settings (Serena registration, .claude/settings.local.json)
#   oma [path] — Install/refresh oh-my-agent (oma) in a project (default: cwd); generate-from-source, idempotent
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load secrets / env overrides from .env if present (gitignored).
# Sourced BEFORE the globals below so .env can override CLAUDE_CONFIG_DIR
# (and any other VAR the globals read via ${VAR:-default}). SCRIPT_DIR is the
# only global it depends on, and that's defined just above.
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="$HOME/.codex"
AGENTS_DIR="$HOME/.agents"
GEMINI_DIR="$HOME/.gemini"
WARNINGS=0
ERRORS=0
SERENA_CONFIG="$HOME/.serena/serena_config.yml"
SKIP_NETWORK=false
SUBCMD="${1:-sync}"
SUBCMD_ARG="${2:-}"

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --skip-network) SKIP_NETWORK=true ;;
  esac
done

# Logging
LOG_DIR="$HOME/.oh-my-agent-env/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup_$(date +%Y%m%d_%H%M%S).log"
STEP_TIMEOUT=120  # seconds per step

# Shared helpers (log, timeout, link, MCP verify/cleanup, codex hooks,
# graphify project config, global rule assembly). Sourced AFTER globals.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/common.sh"

# cmd_sync (sync subcommand body — large, separated for readability)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sync.sh"

# cmd_doctor (diagnostics subcommand)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/doctor.sh"

cmd_validate() {
  echo "=== oh-my-agent-env validate ==="
  for skill_dir in "$SCRIPT_DIR/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "$skill_dir")"
    found=false
    [ -f "$skill_dir/SKILL.md" ] && found=true
    for sub in "$skill_dir"*/SKILL.md; do [ -f "$sub" ] && found=true && break; done
    $found && echo "  [OK] $name" || echo "  [FAIL] $name: no SKILL.md"
  done
  for f in "$SCRIPT_DIR/runtimes/claude/commands/"*.md; do
    [ -f "$f" ] || continue
    head -5 "$f" | grep -q "description:" && echo "  [OK] $(basename "$f")" || echo "  [WARN] $(basename "$f"): no description"
  done
}

cmd_update() {
  echo "=== oh-my-agent-env update ==="
  echo "[1/4] git pull"
  git -C "$SCRIPT_DIR" pull --ff-only 2>&1 | sed 's/^/  /'
  echo "[2/4] validate" && cmd_validate
  echo "[3/4] sync" && cmd_sync
  echo "[4/4] doctor" && cmd_doctor
}

cmd_install() {
  echo "=== oh-my-agent-env install (legacy copy mode) ==="
  mkdir -p "$CONFIG_DIR/commands" "$CONFIG_DIR/hud" "$CODEX_DIR" "$GEMINI_DIR"
  cp "$SCRIPT_DIR/runtimes/claude/commands/"*.md "$CONFIG_DIR/commands/" 2>/dev/null || true
  cp "$SCRIPT_DIR/runtimes/codex/instructions.md" "$CODEX_DIR/" 2>/dev/null || true
  cp "$SCRIPT_DIR/ui/statusline/my-statusline.mjs" "$CONFIG_DIR/hud/" 2>/dev/null || true
  # Global rule files (Layer A + Layer B) for Claude/Codex/Gemini
  assemble_global_rules
  for rt in claude codex agents gemini; do
    for sd in "$SCRIPT_DIR/skills/"*/; do
      dst_base="$HOME/.$rt/skills"
      [ "$rt" = "claude" ] && dst_base="$CONFIG_DIR/skills"
      if [ -d "$sd/$rt" ]; then
        mkdir -p "$dst_base/$(basename "$sd")" && cp "$sd/$rt/"* "$dst_base/$(basename "$sd")/" 2>/dev/null
      elif [ -f "$sd/SKILL.md" ] && { [ "$rt" = "claude" ] || [ "$rt" = "agents" ]; }; then
        mkdir -p "$dst_base/$(basename "$sd")" && cp "$sd/SKILL.md" "$dst_base/$(basename "$sd")/SKILL.md" 2>/dev/null
      fi
    done
  done
  echo "  Legacy install complete."
}

cmd_init_project() {
  local project_path="$1"
  if [ -z "$project_path" ]; then
    echo "Usage: ./setup.sh init-project <path>"
    echo "  Example: ./setup.sh init-project ~/PROject/boltz2"
    exit 1
  fi

  # Resolve to absolute path
  project_path="$(cd "$project_path" 2>/dev/null && pwd)" || {
    echo "[FAIL] Directory not found: $1"
    exit 1
  }
  local project_name
  project_name="$(basename "$project_path")"
  echo "=== oh-my-agent-env init-project: $project_name ==="
  echo "  Path: $project_path"
  echo ""

  # [1] Register with Serena
  echo "[1] Serena project registration"
  if [ -f "$SERENA_CONFIG" ]; then
    if grep -q "$project_path" "$SERENA_CONFIG" 2>/dev/null; then
      echo "    [OK] Already registered in serena_config.yml"
    else
      # Append project path to projects list
      python3 << PYEOF
import sys
try:
    import yaml
except ImportError:
    print("    [WARN] PyYAML missing. pip install pyyaml")
    sys.exit(0)

with open("$SERENA_CONFIG") as f:
    config = yaml.safe_load(f) or {}

projects = config.get("projects", []) or []
if "$project_path" not in projects:
    projects.append("$project_path")
    config["projects"] = projects
    with open("$SERENA_CONFIG", "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    print("    [OK] Registered: $project_path")
else:
    print("    [OK] Already registered")
PYEOF
    fi
  else
    echo "    [SKIP] ~/.serena/serena_config.yml not found (Serena not installed?)"
  fi

  # [2] Create project .serena directory
  echo "[2] Serena project data directory"
  if [ -d "$project_path/.serena" ]; then
    echo "    [OK] $project_path/.serena/ already exists"
  else
    mkdir -p "$project_path/.serena"
    echo "    [OK] Created $project_path/.serena/"
  fi

  # [3] Create .claude/settings.local.json if not exists
  echo "[3] Claude Code project settings"
  local claude_project_dir="$project_path/.claude"
  local settings_local="$claude_project_dir/settings.local.json"
  if [ -f "$settings_local" ]; then
    echo "    [OK] $settings_local already exists"
  else
    mkdir -p "$claude_project_dir"
    cat > "$settings_local" << JSONEOF
{
  "permissions": {},
  "env": {}
}
JSONEOF
    echo "    [OK] Created $settings_local"
  fi

  # [4] Create project CLAUDE.md if not exists
  echo "[4] Project CLAUDE.md"
  if [ -f "$project_path/CLAUDE.md" ]; then
    echo "    [OK] CLAUDE.md already exists"
  else
    cat > "$project_path/CLAUDE.md" << MDEOF
# $project_name

## 기술 스택

| 분류 | 도구 |
|------|------|
| **프레임워크** | |
| **Type Hints** | jaxtyping (필수) |
| **Docstring** | Google style |

## 작업 규칙

### 금지 사항
- 불확실한 내용을 추측으로 답변하지 마세요
- 파일을 읽지 않고 코드에 대해 가정하지 마세요
- 질문 없이 애매한 요구사항을 임의로 해석하지 마세요
MDEOF
    echo "    [OK] Created CLAUDE.md (edit to customize)"
  fi

  # [5] Add .serena to .gitignore if not already
  echo "[5] .gitignore"
  if [ -f "$project_path/.gitignore" ]; then
    if grep -q "^\.serena" "$project_path/.gitignore" 2>/dev/null; then
      echo "    [OK] .serena already in .gitignore"
    else
      echo ".serena/" >> "$project_path/.gitignore"
      echo "    [OK] Added .serena/ to .gitignore"
    fi
  else
    echo ".serena/" > "$project_path/.gitignore"
    echo "    [OK] Created .gitignore with .serena/"
  fi

  write_graphify_project_config "$project_path"

  echo ""
  echo "=== init-project complete: $project_name ==="
  echo "  Next: cd $project_path && claude"
}

# oma — install/refresh oh-my-agent (first-fluke/oh-my-agent) in a project,
# generate-from-source style: oma's generated tree (.agents/, vendor .claude
# subdirs, .mcp.json) is gitignored and regenerated here on each machine; only
# templates/oma/oma-config.yaml is tracked and overlaid so customizations
# survive regeneration. oma install is idempotent, so re-running converges
# settings.json / CLAUDE.md without churn. Coexists with omc-free runtimes.
cmd_oma() {
  local project_path="${1:-$PWD}"
  project_path="$(cd "$project_path" 2>/dev/null && pwd)" || {
    echo "[FAIL] Directory not found: ${1:-$PWD}"
    exit 1
  }
  local oma_version="${OMA_VERSION:-latest}"
  echo "=== oh-my-agent-env oma: $(basename "$project_path") ==="
  echo "  Path: $project_path  (oma@$oma_version)"

  if ! command -v bunx &>/dev/null; then
    echo "  [SKIP] bunx not found — install bun first: https://bun.sh"
    return 0
  fi

  echo "[1] oma install (idempotent)"
  if ( cd "$project_path" && OMA_YES=1 CI=true bunx "oh-my-agent@${oma_version}" install < /dev/null ) \
       2>&1 | grep -v -E 'Resolving|Resolved|warn:|Saved lockfile|→ \.' | sed 's/^/    /'; then
    :
  else
    echo "  [WARN] oma install reported a failure — review output above"
  fi

  # POLICY: .agents/oma-config.yaml is a MANAGED file — overwritten from the
  # repo template on every run. Single source of truth = cross-machine
  # reproducibility + no drift. To change config, edit templates/oma/oma-config.yaml
  # (tracked), NOT the generated copy (local edits there are intentionally lost).
  echo "[2] Overlay canonical oma-config.yaml (managed — edit templates/oma/ to change)"
  local tmpl="$SCRIPT_DIR/templates/oma/oma-config.yaml"
  if [ -f "$tmpl" ] && [ -d "$project_path/.agents" ]; then
    cp "$tmpl" "$project_path/.agents/oma-config.yaml"
    echo "    [OK] applied templates/oma/oma-config.yaml (managed; local edits overwritten)"
  else
    echo "    [SKIP] template or $project_path/.agents missing"
  fi

  # oma re-injects statusLine -> its bun hud.ts into the PROJECT
  # .claude/settings.json on every install/link. settings.local.json is
  # gitignored AND outranks settings.json in Claude Code's settings precedence
  # (local > project > user), so we pin our unified statusline there: it beats
  # oma's hud.ts and survives every oma re-link without touching a tracked file.
  # Merge (preserve permissions/env that init-project writes) + idempotent.
  echo "[3] Pin statusLine in .claude/settings.local.json (beats oma hud.ts)"
  python3 - "$project_path/.claude" << 'PYEOF'
import json, os, sys, tempfile
claude_dir = sys.argv[1]
p = os.path.join(claude_dir, "settings.local.json")
try:
    d = json.load(open(p)) if os.path.exists(p) else {}
    if not isinstance(d, dict): d = {}
except Exception as e:
    print(f"    [WARN] settings.local.json unreadable ({e}); not pinned"); sys.exit(0)
want = {"type": "command", "command": "node $HOME/.claude/hud/my-statusline.mjs"}
if d.get("statusLine") == want:
    print("    [OK] statusLine already pinned (settings.local.json)"); sys.exit(0)
d["statusLine"] = want
os.makedirs(claude_dir, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=claude_dir, suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False); f.write("\n")
os.replace(tmp, p)
print("    [OK] statusLine pinned -> settings.local.json")
PYEOF

  echo "=== oma complete: $(basename "$project_path") ==="
  echo "  Next: cd $project_path && claude   (then name a workflow, e.g. orchestrate)"
}

case "$SUBCMD" in
  sync) cmd_sync ;; doctor) cmd_doctor ;; validate) cmd_validate ;;
  update) cmd_update ;; install) cmd_install ;;
  init-project) cmd_init_project "$SUBCMD_ARG" ;;
  oma) cmd_oma "$SUBCMD_ARG" ;;
  *) echo "Usage: ./setup.sh {sync|doctor|validate|update|install|init-project <path>|oma [path]}"; exit 1 ;;
esac
