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

"$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))

print("== Workflow Phase ==")
print(f"workflow_status: {state.get('workflow_status')}")
print(f"phase:           {state.get('phase')}")
print(f"phase_step:      {state.get('phase_step')}")
print(f"iteration:       {state.get('iteration')}")
print(f"current_exp:     {state.get('current_exp_name')}")
print(f"blocked:         {state.get('blocked')}")
print(f"block_reason:    {state.get('block_reason')}")
print()
print("== Current Iteration ==")
print(f"exp_name:        {current.get('exp_name')}")
print(f"selected:        {current.get('selected_direction')}")
print(f"train_status:    {current.get('remote_training', {}).get('status')}")
print(f"best_val_loss:   {current.get('result', {}).get('best_val_loss')}")
print(f"final_val_loss:  {current.get('result', {}).get('final_val_loss')}")
PY