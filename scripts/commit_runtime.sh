#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -z "${ITERATION:-}" ] && [ -f runtime/state/state.json ]; then
  ITERATION="$(
    .venv/bin/python - <<'PY'
import json
from pathlib import Path

p = Path("runtime/state/state.json")
if p.exists():
    data = json.loads(p.read_text(encoding="utf-8"))
    print(data.get("iteration", "unknown"))
else:
    print("unknown")
PY
  )"
fi

ITERATION="${ITERATION:-unknown}"

# Never use `git add .` or `git add runtime`.
# Runtime contains logs, training outputs, temporary files, and possibly large artifacts.
# Only explicitly whitelisted runtime contract files are allowed.

git add \
  README.md \
  VERSION \
  workflow.config.json \
  pyproject.toml \
  uv.lock \
  .gitignore \
  .gitmodules \
  project/.gitkeep \
  scripts \
  output/.gitkeep \
  workflow/oh-my-autoresearch \
  runtime/CLAUDE.md \
  runtime/objective/objective.yaml \
  runtime/state/state.json \
  runtime/state/current_iteration.json \
  runtime/state/val_loss.json \
  runtime/history/timeline.json \
  runtime/knowledge/learned_patterns.md \
  runtime/knowledge/rejected_ideas.md \
  runtime/debates/.gitkeep \
  runtime/experiments/best.json \
  2>/dev/null || true

# Safety check: block accidentally staged logs, checkpoints, or large model artifacts.
FORBIDDEN_STAGED="$(
  git diff --cached --name-only | grep -E '(^|/)(logs?|output|cache|tmp)/|\.log$|\.out$|\.err$|\.tmp$|\.lock$|\.pt$|\.pth$|\.ckpt$|\.safetensors$|\.bin$' || true
)"

if [ -n "$FORBIDDEN_STAGED" ]; then
  echo "Blocked: forbidden files are staged:"
  echo "$FORBIDDEN_STAGED"
  echo
  echo "Run: git reset"
  echo "Then commit again with ./scripts/commit_runtime.sh"
  exit 1
fi

if git diff --cached --quiet; then
  echo "No runtime changes to commit."
else
  git commit -m "runtime(iteration-${ITERATION}): sync autoresearch state"
fi