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

from scripts.schema_contract import load_schema, validate_against_schema

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")
val_loss_path = Path("runtime/state/val_loss.json")
timeline_path = Path("runtime/history/timeline.json")
best_path = Path("runtime/experiments/best.json")
learned_path = Path("runtime/knowledge/learned_patterns.md")
rejected_path = Path("runtime/knowledge/rejected_ideas.md")

required = [
    state_path,
    current_path,
    val_loss_path,
    timeline_path,
    best_path,
    learned_path,
    rejected_path,
    Path("workflow/oh-my-autoresearch/schemas/best.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/current_iteration.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/experiment.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/state.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/timeline.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/val_loss.schema.json"),
]

missing = [str(p) for p in required if not p.exists()]
if missing:
    raise SystemExit("Missing required Phase F files:\n" + "\n".join(missing))

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))
val_loss = json.loads(val_loss_path.read_text(encoding="utf-8"))
timeline = json.loads(timeline_path.read_text(encoding="utf-8"))
best = json.loads(best_path.read_text(encoding="utf-8"))

root = Path(".").resolve()
best_schema = load_schema(root, "best.schema.json")
current_schema = load_schema(root, "current_iteration.schema.json")
experiment_schema = load_schema(root, "experiment.schema.json")
state_schema = load_schema(root, "state.schema.json")
timeline_schema = load_schema(root, "timeline.schema.json")
val_loss_schema = load_schema(root, "val_loss.schema.json")


def write_json_with_schema(path, data, schema, location):
    validate_against_schema(data, schema, location)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


validate_against_schema(state, state_schema, str(state_path))
validate_against_schema(current, current_schema, str(current_path))
validate_against_schema(val_loss, val_loss_schema, str(val_loss_path))
validate_against_schema(timeline, timeline_schema, str(timeline_path))
validate_against_schema(best, best_schema, str(best_path))

if state.get("phase") != "F":
    print(f"Phase F skipped. Current phase is {state.get('phase')}.")
    raise SystemExit(0)

exp_name = current.get("exp_name")
if not exp_name:
    reason = "Phase F requires current_iteration.exp_name"
    state.update({
        "workflow_status": "blocked",
        "phase": "BLOCKED",
        "phase_step": "BLOCKED",
        "blocked": True,
        "block_reason": reason,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    })
    write_json_with_schema(state_path, state, state_schema, str(state_path))
    raise SystemExit(reason)

experiment_path = Path(f"runtime/experiments/{exp_name}.json")
if not experiment_path.exists():
    reason = f"Phase F requires experiment record: {experiment_path}"
    state.update({
        "workflow_status": "blocked",
        "phase": "BLOCKED",
        "phase_step": "BLOCKED",
        "blocked": True,
        "block_reason": reason,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    })
    write_json_with_schema(state_path, state, state_schema, str(state_path))
    raise SystemExit(reason)

experiment = json.loads(experiment_path.read_text(encoding="utf-8"))
validate_against_schema(experiment, experiment_schema, str(experiment_path))

now = datetime.now(timezone.utc).isoformat()

result = current.get("result", {}) or {}
metrics = experiment.get("metrics", {}) or {}

best_val_loss = result.get("best_val_loss")
if best_val_loss is None:
    best_val_loss = metrics.get("best_val_loss")

final_val_loss = result.get("final_val_loss")
if final_val_loss is None:
    final_val_loss = metrics.get("final_val_loss")

best_epoch = result.get("best_epoch")
if best_epoch is None:
    best_epoch = metrics.get("best_epoch")

has_real_result = best_val_loss is not None

is_new_best = False

print("== Phase F: Checkpoint Write ==")
print(f"exp_name: {exp_name}")
print(f"has_real_result: {has_real_result}")
print(f"best_val_loss: {best_val_loss}")

if has_real_result:
    record = {
        "exp_name": exp_name,
        "iteration": current.get("iteration", state.get("iteration")),
        "best_val_loss": best_val_loss,
        "final_val_loss": final_val_loss,
        "best_epoch": best_epoch,
        "status": "succeeded",
        "updated_at": now,
    }

    records = val_loss.setdefault("records", [])

    # Avoid duplicate val_loss record for same experiment.
    records = [r for r in records if r.get("exp_name") != exp_name]
    records.append(record)
    records.sort(key=lambda r: (
        float("inf") if r.get("best_val_loss") is None else r.get("best_val_loss")
    ))

    val_loss["records"] = records
    write_json_with_schema(val_loss_path, val_loss, val_loss_schema, str(val_loss_path))

    current_best = best.get("best")
    if current_best is None or best_val_loss < current_best.get("best_val_loss", float("inf")):
        is_new_best = True
        best["best"] = record
        write_json_with_schema(best_path, best, best_schema, str(best_path))

    current.setdefault("result", {})
    current["result"].update({
        "status": "succeeded",
        "best_val_loss": best_val_loss,
        "final_val_loss": final_val_loss,
        "best_epoch": best_epoch,
        "is_new_best": is_new_best,
    })

    learned_entry = f"""

## {exp_name}

- Date: {now}
- Iteration: {current.get("iteration", state.get("iteration"))}
- Selected direction: {current.get("selected_direction")}
- Best val_loss: {best_val_loss}
- Final val_loss: {final_val_loss}
- Best epoch: {best_epoch}
- New best: {is_new_best}
- Verdict: accepted as empirically useful.
- Evidence: real validation result was recorded.
- Modification summary: {current.get("code_change_summary")}
"""

    with learned_path.open("a", encoding="utf-8") as f:
        f.write(learned_entry)

    checkpoint_event_type = "phase_f_completed"
    checkpoint_summary = "Experiment had real validation result and checkpoint was written."

else:
    current.setdefault("result", {})
    current["result"].update({
        "status": "pending",
        "best_val_loss": None,
        "final_val_loss": None,
        "best_epoch": None,
        "is_new_best": False,
    })

    rejected_entry = f"""

## {exp_name}

- Date: {now}
- Iteration: {current.get("iteration", state.get("iteration"))}
- Selected direction: {current.get("selected_direction")}
- Verdict: rejected / not evaluated.
- Rejection reason: no real validation result was produced.
- Remote training status: {current.get("remote_training", {}).get("status")}
- Local validation status: {current.get("local_validation", {}).get("status")}
- Modification summary: {current.get("code_change_summary")}
"""

    with rejected_path.open("a", encoding="utf-8") as f:
        f.write(rejected_entry)

    checkpoint_event_type = "phase_f_no_real_result"
    checkpoint_summary = "Experiment produced no real validation result; recorded as not evaluated."

current["updated_at"] = now
write_json_with_schema(current_path, current, current_schema, str(current_path))

timeline.setdefault("events", []).append({
    "time": now,
    "iteration": state.get("iteration", current.get("iteration", 0)),
    "exp_name": exp_name,
    "event_type": checkpoint_event_type,
    "phase": "F",
    "summary": checkpoint_summary,
    "best_val_loss": best_val_loss,
    "is_new_best": is_new_best,
})
write_json_with_schema(timeline_path, timeline, timeline_schema, str(timeline_path))

# Reset current_iteration for the next loop.
next_current = {
    "exp_name": None,
    "iteration": state.get("iteration", current.get("iteration", 0)),
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

write_json_with_schema(current_path, next_current, current_schema, str(current_path))

state.update({
    "workflow_status": "running",
    "phase": "A",
    "phase_step": "A1",
    "current_exp_name": None,
    "next_phase": "A",
    "blocked": False,
    "block_reason": None,
    "updated_at": now,
})

write_json_with_schema(state_path, state, state_schema, str(state_path))

print("Phase F completed. Advanced to Phase A/A1.")
PY
