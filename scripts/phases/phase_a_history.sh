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

required = [
    "runtime/state/state.json",
    "runtime/state/current_iteration.json",
    "runtime/state/val_loss.json",
    "runtime/knowledge/learned_patterns.md",
    "runtime/knowledge/rejected_ideas.md",
    "runtime/history/timeline.json",
    "runtime/experiments/best.json",
]

missing = [p for p in required if not Path(p).exists()]
if missing:
    raise SystemExit("Missing required Phase A files:\n" + "\n".join(missing))

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")
val_loss_path = Path("runtime/state/val_loss.json")
timeline_path = Path("runtime/history/timeline.json")
best_path = Path("runtime/experiments/best.json")

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))
val_loss = json.loads(val_loss_path.read_text(encoding="utf-8"))
timeline = json.loads(timeline_path.read_text(encoding="utf-8"))
best = json.loads(best_path.read_text(encoding="utf-8"))

phase = state.get("phase")
if phase != "A":
    print(f"Phase A skipped. Current phase is {phase}.")
    raise SystemExit(0)

records = val_loss.get("records", [])
events = timeline.get("events", [])

summary = {
    "iteration": state.get("iteration"),
    "current_exp_name": state.get("current_exp_name"),
    "num_val_loss_records": len(records),
    "num_timeline_events": len(events),
    "has_best": best.get("best") is not None,
    "current_iteration_status": current.get("result", {}).get("status"),
}

print("== Phase A: History Maintenance ==")
for key, value in summary.items():
    print(f"{key}: {value}")

events.append({
    "time": datetime.now(timezone.utc).isoformat(),
    "iteration": state.get("iteration", 0),
    "exp_name": state.get("current_exp_name"),
    "event_type": "phase_a_completed",
    "phase": "A",
    "summary": "History/state files were read and workflow context was restored.",
    "best_val_loss": best.get("best", {}).get("best_val_loss") if best.get("best") else None,
    "is_new_best": False
})

timeline["events"] = events
timeline_path.write_text(
    json.dumps(timeline, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8"
)

state["phase"] = "B"
state["phase_step"] = "B1"
state["next_phase"] = "B"
state["updated_at"] = datetime.now(timezone.utc).isoformat()

state_path.write_text(
    json.dumps(state, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8"
)

print("Phase A completed. Advanced to Phase B/B1.")
PY