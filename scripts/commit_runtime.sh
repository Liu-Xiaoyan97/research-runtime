#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ITERATION="${ITERATION:-unknown}"

git add \
  workflow.config.json \
  runtime \
  scripts \
  output/.gitkeep \
  .gitignore \
  .gitmodules \
  workflow/oh-my-autoresearch \
  project/nn-architecture \
  VERSION \
  README.md \
  2>/dev/null || true

if git diff --cached --quiet; then
  echo "No runtime changes to commit."
else
  git commit -m "runtime(iteration-${ITERATION}): sync autoresearch state"
fi