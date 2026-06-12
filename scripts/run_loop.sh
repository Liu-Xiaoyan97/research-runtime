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

echo "== AutoResearch Runtime Loop =="

./scripts/validate_runtime.sh
./scripts/show_phase.sh

echo
echo "== Checking stop conditions =="
if ./scripts/check_stop_conditions.sh; then
  true
else
  code=$?
  if [ "$code" -eq 10 ]; then
    echo "Stop condition reached. Workflow moved to DONE."
    exit 0
  fi
  exit "$code"
fi

PHASE="$("$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path
data = json.loads(Path("runtime/state/state.json").read_text(encoding="utf-8"))
print(data.get("phase"))
PY
)"

echo
echo "== Next Action =="

case "$PHASE" in
  A)
  echo "Run Phase A: History Maintenance"
  ./scripts/phases/phase_a_history.sh
  ;;
  B)
  echo "Run Phase B: Exploration Direction Generation"
  ./scripts/phases/phase_b_exploration.sh
  ;;
  C)
  echo "Run Phase C: Implementation and Local Validation"
  ./scripts/phases/phase_c_local_validation.sh
  ;;
  D)
  echo "Run Phase D: Remote Training Launch"
  ./scripts/phases/phase_d_remote_launch.sh
  ;;
  E)
  echo "Run Phase E: Monitoring and Result Retrieval"
  ./scripts/phases/phase_e_monitoring.sh
  ;;
  F)
  echo "Run Phase F: Checkpoint Write"
  ./scripts/phases/phase_f_checkpoint.sh
  ;;
  BLOCKED)
    echo "Workflow is BLOCKED. Inspect runtime/state/state.json."
    exit 2
    ;;
  DONE)
    echo "Workflow is DONE."
    exit 0
    ;;
  *)
    echo "Unknown phase: $PHASE"
    exit 1
    ;;
esac