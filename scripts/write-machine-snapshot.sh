#!/usr/bin/env bash
# Writes a compact machine snapshot to ~/.cc-bootstrap/local/machine.md
# Run on each machine after setup or when hardware/env changes.
# Output path: $MACHINE_SNAPSHOT_OUT or ~/.cc-bootstrap/local/machine.md
set -euo pipefail

OUT="${MACHINE_SNAPSHOT_OUT:-$HOME/.cc-bootstrap/local/machine.md}"
HOST_LABEL="${MACHINE_SNAPSHOT_HOST:-$(hostname -s)}"

first_line() {
  "$@" 2>/dev/null | sed -n '1p'
}

os_name() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf '%s\n' "${PRETTY_NAME:-unknown}"
  else
    uname -s
  fi
}

cpu_name() {
  if [ -r /proc/cpuinfo ]; then
    sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | sed -n '1p'
  else
    first_line uname -p
  fi
}

ram_total() {
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/ { printf "%.1f GiB\n", $2 / 1024 / 1024 }' /proc/meminfo
  else
    printf 'unknown\n'
  fi
}

gpu_summary() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null |
      sort |
      uniq -c |
      sed 's/^ *//'
  else
    printf 'none detected\n'
  fi
}

nvidia_driver() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | sed -n '1p'
  else
    printf 'n/a\n'
  fi
}

cuda_version() {
  if command -v nvcc >/dev/null 2>&1; then
    nvcc --version 2>/dev/null | sed -n 's/.*release \([^,]*\).*/\1/p' | sed -n '1p'
  elif command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([^ ]*\).*/\1/p' | sed -n '1p'
  else
    printf 'n/a\n'
  fi
}

slurm_status() {
  if command -v sinfo >/dev/null 2>&1; then
    printf 'available\n'
  else
    printf 'not detected\n'
  fi
}

tool_path() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
  else
    printf 'not detected\n'
  fi
}

mkdir -p "$(dirname "$OUT")"

{
  printf '# Machine Snapshot\n\n'
  printf 'Compact local compute snapshot. Do not commit — contains machine-specific paths.\n\n'
  printf -- '- Updated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf -- '- Host label: %s\n' "$HOST_LABEL"
  printf -- '- OS: %s\n' "$(os_name)"
  printf -- '- Kernel: %s\n' "$(uname -r)"
  printf -- '- CPU: %s\n' "$(cpu_name)"
  printf -- '- CPU cores: %s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')"
  printf -- '- RAM: %s\n' "$(ram_total)"
  printf '\n## GPU\n\n'
  gpu_summary | sed 's/^/- /'
  printf '\n## Software\n\n'
  printf -- '- NVIDIA driver: %s\n' "$(nvidia_driver)"
  printf -- '- CUDA: %s\n' "$(cuda_version)"
  printf -- '- Python: %s\n' "$(first_line python3 --version || printf 'not detected')"
  printf -- '- uv: %s\n' "$(first_line uv --version || printf 'not detected')"
  printf -- '- Slurm: %s\n' "$(slurm_status)"
  printf '\n## Agent CLI Paths\n\n'
  printf -- '- claude: %s\n' "$(tool_path claude)"
  printf -- '- codex: %s\n' "$(tool_path codex)"
  printf -- '- agy: %s\n' "$(tool_path agy)"
  printf -- '- gh: %s\n' "$(tool_path gh)"
  printf -- '- uv: %s\n' "$(tool_path uv)"
  printf '\n## Notes\n\n'
  printf -- '- Project envs stay local at `.venv` and run through `uv`.\n'
  printf -- '- Keep private accounts, tokens, and mount paths out of this file.\n'
} > "$OUT"

echo "wrote $OUT"
