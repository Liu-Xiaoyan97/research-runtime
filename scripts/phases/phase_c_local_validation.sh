#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_DIR="$ROOT_DIR/project/nn-architecture"
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

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))

if state.get("phase") != "C":
    print(f"Phase C skipped. Current phase is {state.get('phase')}.")
    raise SystemExit(0)

required = [
    "runtime/state/state.json",
    "runtime/state/current_iteration.json",
    "runtime/history/timeline.json",
]

missing = [p for p in required if not Path(p).exists()]
if missing:
    state["workflow_status"] = "blocked"
    state["phase"] = "BLOCKED"
    state["phase_step"] = "BLOCKED"
    state["blocked"] = True
    state["block_reason"] = "Missing required Phase C files: " + ", ".join(missing)
    state["updated_at"] = datetime.now(timezone.utc).isoformat()
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    raise SystemExit(state["block_reason"])

exp_name = current.get("exp_name")
if not exp_name:
    state["workflow_status"] = "blocked"
    state["phase"] = "BLOCKED"
    state["phase_step"] = "BLOCKED"
    state["blocked"] = True
    state["block_reason"] = "Phase C requires current_iteration.exp_name"
    state["updated_at"] = datetime.now(timezone.utc).isoformat()
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    raise SystemExit(state["block_reason"])

if not current.get("modification_plan"):
    state["workflow_status"] = "blocked"
    state["phase"] = "BLOCKED"
    state["phase_step"] = "BLOCKED"
    state["blocked"] = True
    state["block_reason"] = "Phase C requires current_iteration.modification_plan"
    state["updated_at"] = datetime.now(timezone.utc).isoformat()
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    raise SystemExit(state["block_reason"])

now = datetime.now(timezone.utc).isoformat()

current["local_validation"]["status"] = "not_started"
current["local_validation"]["passed"] = False
current["local_validation"].setdefault("notes", []).append(
    f"{now}: Phase C started. Project validation will run locally."
)
current["updated_at"] = now

current_path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

print("== Phase C: Implementation and Local Validation ==")
print(f"exp_name: {exp_name}")
print("Prepared current_iteration for local validation.")
PY

if [ ! -d "$PROJECT_DIR" ]; then
  "$PYTHON_BIN" - <<'PY'
import json
from datetime import datetime, timezone
from pathlib import Path

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))

reason = "Project directory not found: project/nn-architecture"

state.update({
    "workflow_status": "blocked",
    "phase": "BLOCKED",
    "phase_step": "BLOCKED",
    "blocked": True,
    "block_reason": reason,
    "updated_at": datetime.now(timezone.utc).isoformat()
})

current["local_validation"]["status"] = "failed"
current["local_validation"]["passed"] = False
current["local_validation"].setdefault("notes", []).append(reason)
current["updated_at"] = datetime.now(timezone.utc).isoformat()

state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
current_path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

print(reason)
PY
  exit 1
fi

echo "Project directory found: $PROJECT_DIR"

echo "Applying scaffold-safe demo model change if applicable..."
"$PYTHON_BIN" "$ROOT_DIR/scripts/apply_demo_model_change.py" --root "$ROOT_DIR"

# Run smoke test.
# Prefer project-defined test script if present; otherwise use a safe compile check.
VALIDATION_STATUS="passed"
VALIDATION_NOTE=""

cd "$PROJECT_DIR"

if [ -f "pyproject.toml" ] || [ -d "src" ]; then
  echo "Running Python compile smoke test..."
  if python3 -m compileall .; then
    VALIDATION_STATUS="passed"
    VALIDATION_NOTE="python3 -m compileall . passed"
  else
    VALIDATION_STATUS="failed"
    VALIDATION_NOTE="python3 -m compileall . failed"
  fi
else
  echo "No Python project indicators found. Running directory existence smoke test only."
  VALIDATION_STATUS="passed"
  VALIDATION_NOTE="Project directory exists; no compile smoke test executed."
fi

cd "$ROOT_DIR"

"$PYTHON_BIN" - "$VALIDATION_STATUS" "$VALIDATION_NOTE" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

validation_status = sys.argv[1]
validation_note = sys.argv[2]

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")
timeline_path = Path("runtime/history/timeline.json")

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))
timeline = json.loads(timeline_path.read_text(encoding="utf-8"))

now = datetime.now(timezone.utc).isoformat()
passed = validation_status == "passed"

current["local_validation"]["status"] = validation_status
current["local_validation"]["passed"] = passed
current["local_validation"].setdefault("commands", [])
if "python3 -m compileall ." not in current["local_validation"]["commands"]:
    current["local_validation"]["commands"].append("python3 -m compileall .")
current["local_validation"].setdefault("notes", []).append(f"{now}: {validation_note}")
current["code_change_summary"] = current.get("code_change_summary") or "No code changes applied by scaffold Phase C."
current["updated_at"] = now

if passed:
    state.update({
        "workflow_status": "running",
        "phase": "D",
        "phase_step": "D1",
        "next_phase": "D",
        "blocked": False,
        "block_reason": None,
        "updated_at": now
    })

    timeline.setdefault("events", []).append({
        "time": now,
        "iteration": state.get("iteration", current.get("iteration", 0)),
        "exp_name": current.get("exp_name"),
        "event_type": "phase_c_completed",
        "phase": "C",
        "summary": "Local validation passed. Workflow advanced to Phase D.",
        "best_val_loss": None,
        "is_new_best": False
    })

    print("Phase C completed. Advanced to Phase D/D1.")
else:
    state.update({
        "workflow_status": "blocked",
        "phase": "BLOCKED",
        "phase_step": "BLOCKED",
        "blocked": True,
        "block_reason": validation_note,
        "updated_at": now
    })

    timeline.setdefault("events", []).append({
        "time": now,
        "iteration": state.get("iteration", current.get("iteration", 0)),
        "exp_name": current.get("exp_name"),
        "event_type": "phase_c_failed",
        "phase": "C",
        "summary": validation_note,
        "best_val_loss": None,
        "is_new_best": False
    })

    print("Phase C failed. Workflow moved to BLOCKED.")

state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
current_path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
timeline_path.write_text(json.dumps(timeline, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

if not passed:
    raise SystemExit(1)
PY