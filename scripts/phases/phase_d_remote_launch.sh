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
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from scripts.schema_contract import load_schema, validate_against_schema

try:
    import yaml
except ImportError:
    raise SystemExit("Missing dependency: pyyaml. Install with: uv add pyyaml")

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")
timeline_path = Path("runtime/history/timeline.json")
objective_path = Path("runtime/objective/objective.yaml")
workflow_config_path = Path("workflow.config.json")
training_entrypoint_path = Path("runtime/training/entrypoint.yaml")

required = [
    state_path,
    current_path,
    timeline_path,
    objective_path,
    workflow_config_path,
    Path("workflow/oh-my-autoresearch/schemas/current_iteration.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/state.schema.json"),
    Path("workflow/oh-my-autoresearch/schemas/timeline.schema.json"),
]

missing = [str(p) for p in required if not p.exists()]
if missing:
    raise SystemExit("Missing required Phase D files:\n" + "\n".join(missing))

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))
timeline = json.loads(timeline_path.read_text(encoding="utf-8"))
objective = yaml.safe_load(objective_path.read_text(encoding="utf-8"))
workflow_config = json.loads(workflow_config_path.read_text(encoding="utf-8"))

root = Path(".").resolve()
current_schema = load_schema(root, "current_iteration.schema.json")
state_schema = load_schema(root, "state.schema.json")
timeline_schema = load_schema(root, "timeline.schema.json")


def write_json_with_schema(path: Path, data: dict[str, Any], schema: dict[str, Any]) -> None:
    validate_against_schema(data, schema, str(path))
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def append_timeline(event_type: str, phase: str, summary: str, best_val_loss=None) -> None:
    timeline.setdefault("events", []).append({
        "time": datetime.now(timezone.utc).isoformat(),
        "iteration": state.get("iteration", current.get("iteration", 0)),
        "exp_name": current.get("exp_name"),
        "event_type": event_type,
        "phase": phase,
        "summary": summary,
        "best_val_loss": best_val_loss,
        "is_new_best": False,
    })


def block(reason: str, event_type: str = "phase_d_failed") -> None:
    timestamp = datetime.now(timezone.utc).isoformat()
    state.update({
        "workflow_status": "blocked",
        "phase": "BLOCKED",
        "phase_step": "BLOCKED",
        "blocked": True,
        "block_reason": reason,
        "updated_at": timestamp,
    })
    current["updated_at"] = timestamp
    append_timeline(event_type, "D", reason)
    write_json_with_schema(current_path, current, current_schema)
    write_json_with_schema(timeline_path, timeline, timeline_schema)
    write_json_with_schema(state_path, state, state_schema)
    print(reason)


def remote_training_config() -> dict[str, Any]:
    cfg = workflow_config.get("remote_training")
    if isinstance(cfg, dict):
        return cfg
    objective_cfg = objective.get("remote_training", {}) if isinstance(objective, dict) else {}
    return objective_cfg if isinstance(objective_cfg, dict) else {}


def is_remote_training_enabled(remote_cfg: dict[str, Any]) -> bool:
    if "enable" in remote_cfg:
        return bool(remote_cfg["enable"])
    if "enabled" in remote_cfg:
        return bool(remote_cfg["enabled"])
    return False


def load_training_entrypoint() -> dict[str, Any]:
    if not training_entrypoint_path.exists():
        raise ValueError(f"Missing local training entrypoint: {training_entrypoint_path}")

    data = yaml.safe_load(training_entrypoint_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"Invalid local training entrypoint: {training_entrypoint_path}")

    local = data.get("local")
    if not isinstance(local, dict):
        raise ValueError("training entrypoint missing local section")

    if local.get("enabled", True) is False:
        raise ValueError("training entrypoint local.enabled is false")

    command = local.get("command")
    if not isinstance(command, str) or not command.strip():
        raise ValueError("training entrypoint local.command must be a non-empty string")

    return data


def render_template(value: str | None, exp_name: str) -> str | None:
    if value is None:
        return None
    return value.format(exp_name=exp_name, extra_args="")


def run_local_training(exp_name: str) -> None:
    try:
        entrypoint = load_training_entrypoint()
    except ValueError as exc:
        block(str(exc))
        raise SystemExit(1)

    project_dir = Path(entrypoint.get("project_dir", "project/nn-architecture"))
    if not project_dir.is_absolute():
        project_dir = root / project_dir
    if not project_dir.is_dir():
        block(f"Local training project directory not found: {project_dir}")
        raise SystemExit(1)

    local = entrypoint["local"]
    train_command = render_template(local["command"], exp_name) or local["command"]
    metrics_file_template = local.get("metrics_file")
    metrics_path = render_template(metrics_file_template, exp_name) if isinstance(metrics_file_template, str) else None
    metrics_file = root / metrics_path if metrics_path and not Path(metrics_path).is_absolute() else Path(metrics_path) if metrics_path else None

    log_path_template = local.get("log_path", "runtime/logs/{exp_name}.train.log")
    log_path = render_template(log_path_template, exp_name) if isinstance(log_path_template, str) else None
    log_file = root / log_path if log_path and not Path(log_path).is_absolute() else Path(log_path) if log_path else root / f"runtime/logs/{exp_name}.train.log"
    log_file.parent.mkdir(parents=True, exist_ok=True)

    started_at = datetime.now(timezone.utc).isoformat()
    print("Remote training disabled by workflow.config.json; running local training in Phase D.")
    print(f"+ cd {project_dir.relative_to(root) if project_dir.is_relative_to(root) else project_dir} && {train_command}")

    log_handle = log_file.open("ab")
    try:
        process = subprocess.Popen(
            train_command,
            cwd=project_dir,
            shell=True,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    finally:
        log_handle.close()

    current["remote_training"] = {
        "status": "running",
        "execution_mode": "local",
        "server": None,
        "remote_dir": str(project_dir.relative_to(root) if project_dir.is_relative_to(root) else project_dir),
        "train_command": train_command,
        "main_pid": process.pid,
        "cron_id": None,
        "monitor_interval_minutes": 10,
        "log_path": str(log_file.relative_to(root) if log_file.is_relative_to(root) else log_file),
        "metrics_file": str(metrics_file.relative_to(root) if metrics_file and metrics_file.is_relative_to(root) else metrics_file) if metrics_file else None,
        "started_at": started_at,
        "ended_at": None,
        "notes": [
            "Local training was launched in Phase D because workflow.config.json remote_training.enable/enabled is false.",
            "Phase E must install a cron monitor, check main_pid first, then read metrics only after the process exits."
        ],
    }
    current["result"] = {
        "status": "pending",
        "best_val_loss": None,
        "final_val_loss": None,
        "best_epoch": None,
        "is_new_best": False,
    }
    current["updated_at"] = started_at

    append_timeline(
        "phase_d_local_training_started",
        "D",
        f"Local training started in background with main_pid={process.pid}. Phase E will monitor by cron.",
        best_val_loss=None,
    )

    state.update({
        "workflow_status": "running",
        "phase": "E",
        "phase_step": "E1",
        "next_phase": "E",
        "blocked": False,
        "block_reason": None,
        "updated_at": started_at,
    })

    write_json_with_schema(current_path, current, current_schema)
    write_json_with_schema(timeline_path, timeline, timeline_schema)
    write_json_with_schema(state_path, state, state_schema)

    print(f"Phase D local training started with main_pid={process.pid}. Advanced to Phase E/E1.")

if state.get("phase") != "D":
    print(f"Phase D skipped. Current phase is {state.get('phase')}.")
    raise SystemExit(0)

exp_name = current.get("exp_name")
if not exp_name:
    block("Phase D requires current_iteration.exp_name")
    raise SystemExit(1)

local_validation = current.get("local_validation", {})
if local_validation.get("status") != "passed" or not local_validation.get("passed"):
    block("Phase D requires passed local validation")
    raise SystemExit(1)

remote_cfg = remote_training_config()
enabled = is_remote_training_enabled(remote_cfg)

now = datetime.now(timezone.utc).isoformat()

print("== Phase D: Remote Training Launch ==")
print(f"exp_name: {exp_name}")
print(f"workflow.config.json remote_training enabled: {enabled}")

if not enabled:
    run_local_training(exp_name)
    raise SystemExit(0)

gateway_host = remote_cfg.get("gateway_host")
gpu_host = remote_cfg.get("gpu_host")
shared_home = remote_cfg.get("shared_home")
remote_project_dir = remote_cfg.get("remote_project_dir")
remote_runs_dir = remote_cfg.get("remote_runs_dir")
train_command_template = remote_cfg.get("train_command_template")
log_path_template = remote_cfg.get("log_path_template")
launch_via_gateway = bool(remote_cfg.get("launch_via_gateway", True))

missing_cfg = []
if not gateway_host:
    missing_cfg.append("remote_training.gateway_host")
if not gpu_host:
    missing_cfg.append("remote_training.gpu_host")
if not shared_home:
    missing_cfg.append("remote_training.shared_home")
if not remote_project_dir:
    missing_cfg.append("remote_training.remote_project_dir")
if not remote_runs_dir:
    missing_cfg.append("remote_training.remote_runs_dir")
if not train_command_template:
    missing_cfg.append("remote_training.train_command_template")
if not log_path_template:
    missing_cfg.append("remote_training.log_path_template")

if missing_cfg:
    reason = "Phase D remote training enabled but missing config: " + ", ".join(missing_cfg)

    current.setdefault("remote_training", {})
    current["remote_training"].update({
        "status": "failed",
        "server": gateway_host,
        "gateway_host": gateway_host,
        "gpu_host": gpu_host,
        "shared_home": shared_home,
        "remote_dir": remote_project_dir,
        "remote_runs_dir": remote_runs_dir,
        "train_command": train_command_template.format(exp_name=exp_name) if train_command_template else None,
        "log_path": log_path_template.format(exp_name=exp_name) if log_path_template else None,
        "launch_via_gateway": launch_via_gateway,
        "started_at": None,
        "ended_at": now,
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
        "event_type": "phase_d_failed",
        "phase": "D",
        "summary": reason,
        "best_val_loss": None,
        "is_new_best": False,
    })

    write_json_with_schema(current_path, current, current_schema)
    write_json_with_schema(timeline_path, timeline, timeline_schema)
    write_json_with_schema(state_path, state, state_schema)

    print(reason)
    raise SystemExit(1)

# Safety: remote execution is intentionally not implemented yet.
reason = (
    "Remote training is enabled and config exists, but Phase D remote execution "
    "is intentionally disabled in the scaffold. Implement ssh/scp launch logic later."
)

current.setdefault("remote_training", {})
current["remote_training"].update({
    "status": "failed",
    "server": gateway_host,
    "gateway_host": gateway_host,
    "gpu_host": gpu_host,
    "shared_home": shared_home,
    "remote_dir": remote_project_dir,
    "remote_runs_dir": remote_runs_dir,
    "train_command": train_command_template.format(exp_name=exp_name),
    "cron_id": None,
    "log_path": log_path_template.format(exp_name=exp_name),
    "launch_via_gateway": launch_via_gateway,
    "started_at": None,
    "ended_at": now,
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
    "event_type": "phase_d_blocked",
    "phase": "D",
    "summary": reason,
    "best_val_loss": None,
    "is_new_best": False,
})

write_json_with_schema(current_path, current, current_schema)
write_json_with_schema(timeline_path, timeline, timeline_schema)
write_json_with_schema(state_path, state, state_schema)

print(reason)
raise SystemExit(1)
PY
