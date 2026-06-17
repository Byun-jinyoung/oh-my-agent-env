---
name: slurm-hpc
description: >
  Slurm/HPC workflow helper. Use when working on clusters, partitions, nodes,
  sbatch/srun jobs, GPU/CPU allocations, queues, logs, checkpoints, or any
  resource-heavy command. Reads local cluster reference when generated.
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion
user-invocable: true
---

# Slurm/HPC Skill (/slurm-hpc)

## Rules

- If Slurm commands exist, prefer `sbatch` for long jobs and allocated `srun` for interactive work.
- Never run long/GPU/high-CPU jobs directly on login nodes.
- Confirm partition, account, time, GPU/CPU/mem, output path before heavy jobs.
- Job scripts should use `set -euo pipefail`, `cd "$SLURM_SUBMIT_DIR"`, and `%x-%j` logs.
- Python jobs should use project-local commands, usually `uv run`.
- Track job id, command, config, seed, commit, checkpoint, and log path.

## Local Cluster Reference

If present, read `references/cluster.generated.md` (relative to this skill
directory) before suggesting partitions, nodes, GPU types, limits, or default
Slurm resources.

If missing, ask the user to run:

```bash
~/.oh-my-agent-env/scripts/generate-slurm-skill.sh
```

This writes `skills/slurm-hpc/references/cluster.generated.md` (gitignored,
machine-specific). The reference is regenerated per machine.

## Useful Commands

```bash
sinfo
squeue -u "$USER"
scontrol show partition
scontrol show node <node>
sacct -j <job_id>
scancel <job_id>
```
