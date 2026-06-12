#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
timeline_path = Path("runtime/history/timeline.json")
val_loss_path = Path("runtime/state/val_loss.json")

required = [
    state_path,
    current_path,
    timeline_path,
    val_loss_path,
]

missing = [str(p) for p in required if not p.exists()]
if missing:
    raise SystemExit("Missing required Phase E files:\n" + "\n".join(missing))

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))
timeline = json.loads(timeline_path.read_text(encoding="utf-8"))
val_loss = json.loads(val_loss_path.read_text(encoding="utf-8"))

if state.get("phase") != "E":
    print(f"Phase E skipped. Current phase is {state.get('phase')}.")
    raise SystemExit(0)

exp_name = current.get("exp_name")
if not exp_name:
    reason = "Phase E requires current_iteration.exp_name"
    state.update({
        "workflow_status": "blocked",
        "phase": "BLOCKED",
        "phase_step": "BLOCKED",
        "blocked": True,
        "block_reason": reason,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    })
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    raise SystemExit(reason)

remote_training = current.get("remote_training", {})
remote_status = remote_training.get("status")

now = datetime.now(timezone.utc).isoformat()

print("== Phase E: Monitoring and Result Retrieval ==")
print(f"exp_name: {exp_name}")
print(f"remote_training.status: {remote_status}")

experiment_path = Path(f"runtime/experiments/{exp_name}.json")
if experiment_path.exists():
    print(f"Experiment file already exists and will not be overwritten: {experiment_path}")
else:
    experiment_record = {
        "exp_name": exp_name,
        "iteration": current.get("iteration", state.get("iteration")),
        "created_at": now,
        "status": "pending",
        "phase": "E",
        "objective_summary": current.get("objective_summary"),
        "selected_direction": current.get("selected_direction"),
        "candidate_directions": current.get("candidate_directions", []),
        "deduplicated_directions": current.get("deduplicated_directions", []),
        "modification_plan": current.get("modification_plan"),
        "code_change_summary": current.get("code_change_summary"),
        "local_validation": current.get("local_validation", {}),
        "remote_training": remote_training,
        "metrics": {
            "best_val_loss": None,
            "final_val_loss": None,
            "best_epoch": None,
            "loss_curve": []
        },
        "notes": [
            "Phase E scaffold generated this experiment record.",
            "No real remote training result was retrieved."
        ]
    }

    experiment_path.write_text(
        json.dumps(experiment_record, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8"
    )
    print(f"Created experiment record: {experiment_path}")

if remote_status == "not_started":
    current["result"] = {
        "status": "pending",
        "best_val_loss": None,
        "final_val_loss": None,
        "best_epoch": None,
        "is_new_best": False
    }

    current.setdefault("remote_training", {}).setdefault("ended_at", now)
    current["updated_at"] = now

    timeline.setdefault("events", []).append({
        "time": now,
        "iteration": state.get("iteration", current.get("iteration", 0)),
        "exp_name": exp_name,
        "event_type": "phase_e_skipped",
        "phase": "E",
        "summary": "Monitoring skipped because remote training was not started.",
        "best_val_loss": None,
        "is_new_best": False
    })

    state.update({
        "workflow_status": "running",
        "phase": "F",
        "phase_step": "F1",
        "next_phase": "F",
        "blocked": False,
        "block_reason": None,
        "updated_at": now,
    })

    current_path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    timeline_path.write_text(json.dumps(timeline, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print("Phase E skipped. Advanced to Phase F/F1.")
    raise SystemExit(0)

# Real monitoring is intentionally not implemented yet.
reason = (
    "Phase E real monitoring is not implemented yet. "
    "Expected scaffold input is remote_training.status = skipped."
)

current.setdefault("result", {})
current["result"].update({
    "status": "failed",
    "best_val_loss": None,
    "final_val_loss": None,
    "best_epoch": None,
    "is_new_best": False
})
current["updated_at"] = now

state.update({
    "workflow_status": "blocked",
    "phase": "BLOCKED",
    "phase_step": "BLOCKED",
    "blocked": True,
    "block_reason": reason,
    "updated_at": now,
})

timeline.setdefault("events", []).append({
    "time": now,
    "iteration": state.get("iteration", current.get("iteration", 0)),
    "exp_name": exp_name,
    "event_type": "phase_e_blocked",
    "phase": "E",
    "summary": reason,
    "best_val_loss": None,
    "is_new_best": False
})

current_path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
timeline_path.write_text(json.dumps(timeline, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

print(reason)
raise SystemExit(1)
PY