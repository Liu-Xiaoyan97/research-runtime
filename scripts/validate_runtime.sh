#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_DIR="$ROOT_DIR/workflow/oh-my-autoresearch"
PYTHON_BIN="$ROOT_DIR/.venv/bin/python"

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi

if [ -z "${PYTHON_BIN:-}" ]; then
  echo "Python not found. Expected .venv/bin/python or python3."
  exit 1
fi

echo "ROOT_DIR=$ROOT_DIR"
echo "WORKFLOW_DIR=$WORKFLOW_DIR"
echo "Using Python: $PYTHON_BIN"

"$PYTHON_BIN" "$WORKFLOW_DIR/scripts/validate_workflow.py" \
  --root "$ROOT_DIR"