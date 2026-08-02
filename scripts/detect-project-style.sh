#!/usr/bin/env bash
# Pick the project style whose rule set gets installed into a repo's CLAUDE.md.
# Getting this wrong is not cosmetic: apply-project-template.sh feeds the answer
# straight into which managed block it writes, so a misfire installs ML rules and
# an ML verify contract into a repo that has no model in it.
#
# Every signal below has to be a *use*, not a mention. The previous version
# matched torch|tensorflow|jax|... as a bare substring across *.sh, *.yaml and
# *.toml as well as *.py, which meant:
#   - this shell harness classified as `ml`, because setup.sh names `jaxtyping`
#     in a documentation table and `jax` is a substring of it;
#   - PROject/data_utils classified as `ml` on two commented-out `#import torch`
#     lines;
#   - measured over 9 repos, the old rules answered `ml` for all 9, including the
#     two with no ML import anywhere.
set -euo pipefail

DIR="${1:-$PWD}"

ML_MODULES='torch|tensorflow|jax|sklearn|keras|lightning|pytorch_lightning|transformers|xgboost|lightgbm'

# Entry-point filenames. Generic config names (`configs`, `config.yaml`) used to
# live here and were dropped: they are convention in Hydra ML repos but also in
# most non-ML services, so they carried no information. A repo that keeps its ML
# deps in a manifest and its config in `configs/` is still caught below.
exists_any() {
  local pattern
  for pattern in "$@"; do
    if find "$DIR" -maxdepth 3 -path "$DIR/.git" -prune -o -name "$pattern" -print -quit | grep -q .; then
      return 0
    fi
  done
  return 1
}

# An anchored import in a real .py file. Anchoring at line start is what rejects
# `#import torch`, `"torch",` in a keyword list, and prose in a docstring — all
# three were live false positives here.
has_ml_import() {
  if command -v rg >/dev/null 2>&1; then
    rg -q --no-messages "^[[:space:]]*(import|from)[[:space:]]+($ML_MODULES)\b" "$DIR" \
      -g '*.py' -g '!/.git' -g '!/.venv' -g '!node_modules' -g '!__pycache__' 2>/dev/null
  else
    find "$DIR" -maxdepth 3 -path "$DIR/.git" -prune -o -name '*.py' -print0 2>/dev/null \
      | xargs -0 -r grep -lE "^[[:space:]]*(import|from)[[:space:]]+($ML_MODULES)([^[:alnum:]_]|$)" 2>/dev/null \
      | grep -q .
  fi
}

# A declared dependency. Kept separate from the import scan because a repo can
# depend on torch and import it lazily, or vendor its training code elsewhere.
# Whole-word matching is safe here in a way it is not in source: these files are
# dependency lists, so the name appearing at all is the declaration.
has_ml_dependency() {
  local f
  while IFS= read -r f; do
    grep -qEi "(^|[^[:alnum:]_])($ML_MODULES)([^[:alnum:]_]|$)" "$f" 2>/dev/null && return 0
  done < <(find "$DIR" -maxdepth 3 -path "$DIR/.git" -prune -o \
             \( -name 'requirements*.txt' -o -name 'pyproject.toml' \
                -o -name 'environment.yml' -o -name 'environment.yaml' \) -print 2>/dev/null)
  return 1
}

style="general"
# Cheapest test first; the answer is the same in any order.
if exists_any "train.py" "infer.py" "inference.py" "dataset.py" "dataloader.py" "model.py"; then
  style="ml"
elif has_ml_dependency; then
  style="ml"
elif has_ml_import; then
  style="ml"
fi

echo "$style"
