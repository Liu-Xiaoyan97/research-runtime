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

START_ITERATION="$("$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path

state = json.loads(Path("runtime/state/state.json").read_text(encoding="utf-8"))
print(state.get("iteration", 0))
PY
)"

START_PHASE="$("$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path

state = json.loads(Path("runtime/state/state.json").read_text(encoding="utf-8"))
print(state.get("phase"))
PY
)"

echo "== AutoResearch One Cycle =="
echo "start_iteration: $START_ITERATION"
echo "start_phase: $START_PHASE"

if [ "$START_PHASE" != "A" ]; then
  echo "Refusing to run one full cycle unless current phase is A."
  echo "Current phase: $START_PHASE"
  exit 1
fi

for step in 1 2 3 4 5 6 7 8 9 10; do
  echo
  echo "== Cycle step $step =="
  ./scripts/run_loop.sh

  PHASE="$("$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path

state = json.loads(Path("runtime/state/state.json").read_text(encoding="utf-8"))
print(state.get("phase"))
PY
  )"

  ITERATION="$("$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path

state = json.loads(Path("runtime/state/state.json").read_text(encoding="utf-8"))
print(state.get("iteration", 0))
PY
  )"

  BLOCKED="$("$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path

state = json.loads(Path("runtime/state/state.json").read_text(encoding="utf-8"))
print(str(bool(state.get("blocked", False))).lower())
PY
  )"

  echo "phase: $PHASE"
  echo "iteration: $ITERATION"
  echo "blocked: $BLOCKED"

  if [ "$BLOCKED" = "true" ]; then
    echo "Workflow became BLOCKED."
    exit 2
  fi

  if [ "$PHASE" = "A" ] && [ "$ITERATION" != "$START_ITERATION" ]; then
    echo "One cycle completed."
    ./scripts/show_phase.sh
    exit 0
  fi
done

echo "Cycle did not complete within 10 steps."
exit 1