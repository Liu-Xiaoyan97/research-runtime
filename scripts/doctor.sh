#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="$ROOT_DIR/.venv/bin/python"

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi

if [ -z "${PYTHON_BIN:-}" ]; then
  echo "Python not found. Expected .venv/bin/python or python3."
  exit 1
fi

cd "$ROOT_DIR"

echo "== AutoResearch Doctor =="

echo
echo "== Runtime validation =="
./scripts/validate_runtime.sh

echo
echo "== Phase =="
./scripts/show_phase.sh

echo
echo "== Git status =="
git status --short

echo
echo "== Ignored project workspace check =="
if [ -d project/nn-architecture ]; then
  if git check-ignore -q project/nn-architecture/pyproject.toml 2>/dev/null; then
    echo "project/nn-architecture is ignored by autoresearch-runtime Git: OK"
  else
    echo "WARNING: project/nn-architecture may not be ignored."
  fi
else
  echo "project/nn-architecture not found."
fi

echo
echo "== Runtime generated files =="
echo "Debates:"
find runtime/debates -maxdepth 1 -type f -name '*.md' -print | sort || true

echo
echo "Experiments:"
find runtime/experiments -maxdepth 1 -type f -name '*.json' ! -name 'best.json' -print | sort || true

echo
echo "== Forbidden tracked files check =="
FORBIDDEN="$(
  git ls-files \
    | grep -E '(^|/)(logs?|output|cache|tmp)/|\.log$|\.out$|\.err$|\.tmp$|\.lock$|\.pt$|\.pth$|\.ckpt$|\.safetensors$|\.bin$' \
    | grep -v '^output/\.gitkeep$' \
    | grep -v '^project/\.gitkeep$' \
    || true
)"

if [ -n "$FORBIDDEN" ]; then
  echo "Forbidden files are tracked:"
  echo "$FORBIDDEN"
  exit 1
else
  echo "No forbidden tracked files detected."
fi

echo
echo "Doctor check completed."