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
from datetime import datetime, timezone
from pathlib import Path

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")

state = json.loads(state_path.read_text(encoding="utf-8"))
iteration = state.get("iteration", 0)
now = datetime.now(timezone.utc).isoformat()

current = {
    "exp_name": None,
    "iteration": iteration,
    "objective_summary": None,
    "selected_direction": None,
    "candidate_directions": [],
    "deduplicated_directions": [],
    "modification_plan": None,
    "code_change_summary": None,
    "local_validation": {
        "status": "not_started",
        "commands": [],
        "passed": False,
        "notes": []
    },
    "remote_training": {
        "status": "not_started",
        "server": None,
        "remote_dir": None,
        "train_command": None,
        "cron_id": None,
        "log_path": None,
        "started_at": None,
        "ended_at": None
    },
    "result": {
        "status": "pending",
        "best_val_loss": None,
        "final_val_loss": None,
        "best_epoch": None,
        "is_new_best": False
    },
    "root_cause_analysis": {
        "status": "not_started",
        "agent_votes": [],
        "verdict": None,
        "summary": None
    },
    "updated_at": now
}

current_path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

state.update({
    "workflow_status": "running",
    "phase": "A",
    "phase_step": "A1",
    "current_exp_name": None,
    "next_phase": "A",
    "blocked": False,
    "block_reason": None,
    "updated_at": now
})

state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

print("Current iteration reset. Workflow moved to A/A1.")
PY