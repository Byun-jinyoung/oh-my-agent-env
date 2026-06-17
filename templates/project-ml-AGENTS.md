# ML Project Guidelines

> Reference template for ML project CLAUDE.md / AGENTS.md files.
> Copy relevant sections into the project's CLAUDE.md and adapt.

## Output And Artifacts

- Compact, direct, low-token. Fragments and arrows OK when clear.
- Commit messages: Conventional Commits; subject <= 50 chars; body only for non-obvious why/risk.
- Markdown/docs: short sections, bullets, direct commands; keep setup, safety, and specs explicit.

## ML Startup Workflow

1. Read `PROJECT.md` if present. If absent or `State: draft`, run `/spec-interview`.
2. Read machine snapshot at `~/.oh-my-agent-env/local/machine.md` when compute, GPU/CUDA, Slurm,
   memory, or environment details affect the task.
3. Confirm data paths, splits, and metric before writing any training code.
4. Run smoke check (small batch, 1 step) before full training.

## Standard ML Layout

```text
.
|-- configs/
|-- data/
|   |-- raw/
|   `-- processed/
|-- docs/
|-- notebooks/
|-- outputs/
|-- scripts/
|   |-- train.py
|   |-- eval.py
|   `-- infer.py
|-- src/
|   `-- project_name/
|       |-- data/
|       |-- models/
|       |-- training/
|       |-- evaluation/
|       `-- utils/
`-- tests/
```

- `scripts/` are thin CLI entrypoints; reusable logic belongs under `src/`.
- Notebooks are exploration only; do not make production code depend on notebooks.
- Keep configs in `configs/`; do not hardcode experiment hyperparameters in scripts.
- Treat `data/raw`, `data/processed`, `outputs`, `checkpoints`, `wandb`, and `runs` as
  gitignored unless explicitly intended.
- Do not commit private data, large datasets, checkpoints, generated outputs, or real secrets.

## Environment

- Use `uv` for Python envs: `uv sync`, `uv add`, `uv run`.
- Keep project env local at `.venv`; do not use global Python/pip unless confirmed.
- Read machine specs from `~/.oh-my-agent-env/local/machine.md` when compute affects behavior.
- Do not duplicate full machine specs into project docs; record only project-specific compute constraints.
- Update machine snapshot when GPU, driver/CUDA, RAM, storage, Slurm partition, or Python base changes.

## Docs

- Keep `docs/` for planning, analysis, progress, and decisions — use Obsidian-visible paths
  (vault/Research/<project>/docs/) so notes are accessible from the vault.
- `PROJECT.md` at repo root: spec, commands, paths, verification criteria.
- Commit training results (metric, config, split) as brief notes in `docs/` or `outputs/`.
- Do not put large result dumps in docs; link to output files instead.

## Test Strategy

- Prefer behavior/interface tests over tiny per-function tests.
- Test behavior at module/interface boundaries.
- Add narrow unit tests only for fragile pure logic or past bugs.
- Always include a smoke test: 1 batch forward + backward, assert loss finite.

## ML Reliability

- Pin random seeds (Python, numpy, torch) for reproducibility.
- Log: job id, command, config, seed, commit hash, checkpoint path, key metrics.
- Save checkpoint at minimum at end of training; save best-val checkpoint separately.

## ML Safety Stop

- Never infer label meaning, split policy, leakage boundary, or metric direction from file names alone.
- Ask before using validation/test data for preprocessing fit, feature selection, normalization,
  threshold tuning, checkpoint choice, or early stopping.
- Do not run long training unless data, dataloader, model, and loss smoke checks pass.

## Project Commands

Fill in per-project:

```
- Setup:   uv sync
- Train:   uv run scripts/train.py configs/default.yaml
- Eval:    uv run scripts/eval.py
- Test:    uv run pytest tests/
- Lint:    uv run ruff check src/
```

## Project Contracts

- `PROJECT.md` at repo root is the source of truth for spec, commands, and verification.
- Never modify `data/raw/`; all preprocessing writes to `data/processed/`.
- `outputs/` and `checkpoints/` are gitignored; document paths in `PROJECT.md`.
