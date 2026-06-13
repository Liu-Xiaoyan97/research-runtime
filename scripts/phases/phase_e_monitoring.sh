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
import os
import shlex
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from scripts.schema_contract import load_schema, validate_against_schema

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")
timeline_path = Path("runtime/history/timeline.json")
val_loss_path = Path("runtime/state/val_loss.json")

required = [
    state_path,
    current_path,
    timeline_path,
    val_loss_path,
    Path("workflow/oh-my-autoresearch/schemas/current_iteration.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/experiment.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/state.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/timeline.schema.json"),
]

missing = [str(p) for p in required if not p.exists()]
if missing:
    raise SystemExit("Missing required Phase E files:\n" + "\n".join(missing))

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))
timeline = json.loads(timeline_path.read_text(encoding="utf-8"))
val_loss = json.loads(val_loss_path.read_text(encoding="utf-8"))

root = Path(".").resolve()
current_schema = load_schema(root, "current_iteration.schema.json")
experiment_schema = load_schema(root, "experiment.schema.json")
state_schema = load_schema(root, "state.schema.json")
timeline_schema = load_schema(root, "timeline.schema.json")


def write_json_with_schema(path, data, schema, location):
    validate_against_schema(data, schema, location)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def append_timeline(event_type, summary, best_val_loss=None):
    timeline.setdefault("events", []).append({
        "time": datetime.now(timezone.utc).isoformat(),
        "iteration": state.get("iteration", current.get("iteration", 0)),
        "exp_name": current.get("exp_name"),
        "event_type": event_type,
        "phase": "E",
        "summary": summary,
        "best_val_loss": best_val_loss,
        "is_new_best": False,
    })


def process_alive(pid):
    try:
        pid_int = int(pid)
    except (TypeError, ValueError):
        return False
    if pid_int <= 0:
        return False
    try:
        os.kill(pid_int, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_json_file(path):
    return json.loads(path.read_text(encoding="utf-8"))


def metrics_path_from_remote(remote_training):
    metrics_file = remote_training.get("metrics_file")
    if not isinstance(metrics_file, str) or not metrics_file:
        return None
    path = Path(metrics_file)
    return path if path.is_absolute() else root / path


def cron_marker(exp_name):
    return f"autoresearch-monitor:{exp_name}"


def read_crontab():
    completed = subprocess.run(
        ["crontab", "-l"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode == 0:
        return completed.stdout.splitlines()
    if "no crontab" in completed.stderr.lower():
        return []
    raise RuntimeError(completed.stderr.strip() or "crontab -l failed")


def write_crontab(lines):
    payload = "\n".join(lines).rstrip()
    if payload:
        payload += "\n"
    completed = subprocess.run(
        ["crontab", "-"],
        input=payload,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "crontab install failed")


def install_monitor_cron(exp_name):
    marker = cron_marker(exp_name)
    lines = read_crontab()
    if any(marker in line for line in lines):
        return marker

    log_dir = root / "runtime/logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "phase_e_monitoring.log"
    command = (
        f"cd {shlex.quote(str(root))} && "
        f"./scripts/phases/phase_e_monitoring.sh >> {shlex.quote(str(log_file))} 2>&1"
    )
    lines.append(f"*/10 * * * * {command} # {marker}")
    write_crontab(lines)
    return marker


def cancel_monitor_cron(cron_id):
    if not cron_id:
        return False
    lines = read_crontab()
    filtered = [line for line in lines if cron_id not in line]
    if filtered == lines:
        return False
    write_crontab(filtered)
    return True


def write_common_state():
    write_json_with_schema(current_path, current, current_schema, str(current_path))
    write_json_with_schema(timeline_path, timeline, timeline_schema, str(timeline_path))
    write_json_with_schema(state_path, state, state_schema, str(state_path))


validate_against_schema(state, state_schema, str(state_path))
validate_against_schema(current, current_schema, str(current_path))
validate_against_schema(timeline, timeline_schema, str(timeline_path))

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
    write_json_with_schema(state_path, state, state_schema, str(state_path))
    raise SystemExit(reason)

remote_training = current.get("remote_training", {})
remote_status = remote_training.get("status")
result = current.get("result", {}) or {}
local_training_succeeded = (
    remote_status == "succeeded"
    and remote_training.get("execution_mode") == "local"
    and result.get("status") == "succeeded"
)

now = datetime.now(timezone.utc).isoformat()

print("== Phase E: Monitoring and Result Retrieval ==")
print(f"exp_name: {exp_name}")
print(f"remote_training.status: {remote_status}")
print(f"remote_training.execution_mode: {remote_training.get('execution_mode')}")

if remote_status == "running" and remote_training.get("execution_mode") == "local":
    main_pid = remote_training.get("main_pid")
    if not main_pid:
        reason = "Phase E local monitoring requires remote_training.main_pid"
        state.update({
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": now,
        })
        append_timeline("phase_e_blocked", reason)
        write_common_state()
        raise SystemExit(reason)

    try:
        cron_id = install_monitor_cron(exp_name)
    except RuntimeError as exc:
        reason = f"Phase E failed to install 10-minute cron monitor: {exc}"
        state.update({
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": now,
        })
        append_timeline("phase_e_cron_failed", reason)
        write_common_state()
        raise SystemExit(reason)

    current.setdefault("remote_training", {})
    current["remote_training"]["cron_id"] = cron_id
    current["remote_training"]["monitor_interval_minutes"] = 10
    current["remote_training"]["last_checked_at"] = now

    metrics_file = metrics_path_from_remote(current["remote_training"])
    alive = process_alive(main_pid)

    if alive:
        if metrics_file and metrics_file.exists():
            try:
                partial_metrics = read_json_file(metrics_file)
            except json.JSONDecodeError:
                partial_metrics = {}
            best_val_loss = partial_metrics.get("best_val_loss")
            final_val_loss = partial_metrics.get("final_val_loss")
            best_epoch = partial_metrics.get("best_epoch")
            if best_val_loss is not None:
                current["result"] = {
                    "status": "pending",
                    "best_val_loss": best_val_loss,
                    "final_val_loss": final_val_loss,
                    "best_epoch": best_epoch,
                    "is_new_best": False,
                }

        current["updated_at"] = now
        state.update({
            "workflow_status": "running",
            "phase": "E",
            "phase_step": "E1",
            "next_phase": "E",
            "blocked": False,
            "block_reason": None,
            "updated_at": now,
        })
        append_timeline(
            "phase_e_monitoring_active",
            f"Phase E cron monitor active for main_pid={main_pid}; training process is still running.",
            best_val_loss=current.get("result", {}).get("best_val_loss"),
        )
        write_common_state()
        print(f"Training process main_pid={main_pid} is still running.")
        print(f"cron_id: {cron_id}")
        print("Phase E remains active; cron will check again in 10 minutes.")
        raise SystemExit(0)

    try:
        cron_removed = cancel_monitor_cron(cron_id)
    except RuntimeError as exc:
        reason = f"Phase E detected finished training but failed to cancel cron {cron_id}: {exc}"
        state.update({
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": now,
        })
        append_timeline("phase_e_cron_cancel_failed", reason)
        write_common_state()
        raise SystemExit(reason)

    if metrics_file is None or not metrics_file.exists():
        reason = f"Phase E detected finished training but metrics file is missing: {metrics_file}"
        current["remote_training"]["status"] = "failed"
        current["remote_training"]["ended_at"] = now
        current["result"] = {
            "status": "failed",
            "best_val_loss": None,
            "final_val_loss": None,
            "best_epoch": None,
            "is_new_best": False,
        }
        state.update({
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": now,
        })
        append_timeline("phase_e_metrics_missing", reason)
        write_common_state()
        raise SystemExit(reason)

    try:
        metrics = read_json_file(metrics_file)
    except json.JSONDecodeError as exc:
        reason = f"Phase E metrics file is invalid JSON: {metrics_file}: {exc}"
        current["remote_training"]["status"] = "failed"
        current["remote_training"]["ended_at"] = now
        state.update({
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": now,
        })
        append_timeline("phase_e_metrics_invalid", reason)
        write_common_state()
        raise SystemExit(reason)

    best_val_loss = metrics.get("best_val_loss")
    final_val_loss = metrics.get("final_val_loss")
    best_epoch = metrics.get("best_epoch")
    metrics_exp_name = metrics.get("exp_name")

    if metrics_exp_name is not None and metrics_exp_name != exp_name:
        reason = f"Phase E metrics exp_name mismatch: expected {exp_name}, got {metrics_exp_name}"
        current["remote_training"]["status"] = "failed"
        current["remote_training"]["ended_at"] = now
        state.update({
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": now,
        })
        append_timeline("phase_e_metrics_mismatch", reason)
        write_common_state()
        raise SystemExit(reason)

    if best_val_loss is None:
        reason = f"Phase E metrics missing best_val_loss: {metrics_file}"
        current["remote_training"]["status"] = "failed"
        current["remote_training"]["ended_at"] = now
        state.update({
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": now,
        })
        append_timeline("phase_e_metrics_incomplete", reason)
        write_common_state()
        raise SystemExit(reason)

    current["remote_training"]["status"] = "succeeded"
    current["remote_training"]["ended_at"] = now
    current["remote_training"]["cron_cancelled_at"] = now
    current["remote_training"]["cron_cancelled"] = cron_removed
    current["result"] = {
        "status": "succeeded",
        "best_val_loss": best_val_loss,
        "final_val_loss": final_val_loss,
        "best_epoch": best_epoch,
        "is_new_best": False,
    }
    current["updated_at"] = now

    experiment_record = {
        "exp_name": exp_name,
        "iteration": current.get("iteration", state.get("iteration")),
        "created_at": now,
        "status": "succeeded",
        "phase": "E",
        "objective_summary": current.get("objective_summary"),
        "selected_direction": current.get("selected_direction"),
        "candidate_directions": current.get("candidate_directions", []),
        "deduplicated_directions": current.get("deduplicated_directions", []),
        "modification_plan": current.get("modification_plan"),
        "code_change_summary": current.get("code_change_summary"),
        "local_validation": current.get("local_validation", {}),
        "remote_training": current["remote_training"],
        "metrics": {
            "best_val_loss": best_val_loss,
            "final_val_loss": final_val_loss,
            "best_epoch": best_epoch,
            "loss_curve": metrics.get("loss_curve", []),
        },
        "notes": [
            "Phase E detected that the main training process exited.",
            f"main_pid={main_pid}",
            f"cron_id={cron_id}",
            f"cron_cancelled={cron_removed}",
        ],
    }

    experiment_path = Path(f"runtime/experiments/{exp_name}.json")
    write_json_with_schema(experiment_path, experiment_record, experiment_schema, str(experiment_path))

    append_timeline(
        "phase_e_training_completed",
        f"Phase E detected training completion for main_pid={main_pid}, read val_loss, and cancelled cron {cron_id}.",
        best_val_loss=best_val_loss,
    )

    state.update({
        "workflow_status": "running",
        "phase": "F",
        "phase_step": "F1",
        "next_phase": "F",
        "blocked": False,
        "block_reason": None,
        "updated_at": now,
    })

    write_common_state()

    print(f"Training process main_pid={main_pid} has exited.")
    print(f"Cancelled cron_id: {cron_id}")
    print(f"best_val_loss: {best_val_loss}")
    print("Phase E completed. Advanced to Phase F/F1.")
    raise SystemExit(0)

experiment_metrics = {
    "best_val_loss": result.get("best_val_loss") if local_training_succeeded else None,
    "final_val_loss": result.get("final_val_loss") if local_training_succeeded else None,
    "best_epoch": result.get("best_epoch") if local_training_succeeded else None,
    "loss_curve": [],
}

experiment_path = Path(f"runtime/experiments/{exp_name}.json")
if experiment_path.exists():
    print(f"Experiment file already exists and will not be overwritten: {experiment_path}")
    experiment_record = json.loads(experiment_path.read_text(encoding="utf-8"))
    validate_against_schema(experiment_record, experiment_schema, str(experiment_path))
else:
    experiment_record = {
        "exp_name": exp_name,
        "iteration": current.get("iteration", state.get("iteration")),
        "created_at": now,
        "status": "succeeded" if local_training_succeeded else "pending",
        "phase": "E",
        "objective_summary": current.get("objective_summary"),
        "selected_direction": current.get("selected_direction"),
        "candidate_directions": current.get("candidate_directions", []),
        "deduplicated_directions": current.get("deduplicated_directions", []),
        "modification_plan": current.get("modification_plan"),
        "code_change_summary": current.get("code_change_summary"),
        "local_validation": current.get("local_validation", {}),
        "remote_training": remote_training,
        "metrics": experiment_metrics,
        "notes": [
            "Phase E generated this experiment record.",
            (
                "Local training metrics were produced by Phase D."
                if local_training_succeeded
                else "No real remote training result was retrieved."
            )
        ]
    }

    write_json_with_schema(experiment_path, experiment_record, experiment_schema, str(experiment_path))
    print(f"Created experiment record: {experiment_path}")

if local_training_succeeded:
    current["updated_at"] = now

    timeline.setdefault("events", []).append({
        "time": now,
        "iteration": state.get("iteration", current.get("iteration", 0)),
        "exp_name": exp_name,
        "event_type": "phase_e_local_result_recorded",
        "phase": "E",
        "summary": "Phase E recorded metrics produced by local Phase D training.",
        "best_val_loss": result.get("best_val_loss"),
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

    write_json_with_schema(current_path, current, current_schema, str(current_path))
    write_json_with_schema(timeline_path, timeline, timeline_schema, str(timeline_path))
    write_json_with_schema(state_path, state, state_schema, str(state_path))

    print("Phase E recorded local training results. Advanced to Phase F/F1.")
    raise SystemExit(0)

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

    write_json_with_schema(current_path, current, current_schema, str(current_path))
    write_json_with_schema(timeline_path, timeline, timeline_schema, str(timeline_path))
    write_json_with_schema(state_path, state, state_schema, str(state_path))

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

write_json_with_schema(current_path, current, current_schema, str(current_path))
write_json_with_schema(timeline_path, timeline, timeline_schema, str(timeline_path))
write_json_with_schema(state_path, state, state_schema, str(state_path))

print(reason)
raise SystemExit(1)
PY
