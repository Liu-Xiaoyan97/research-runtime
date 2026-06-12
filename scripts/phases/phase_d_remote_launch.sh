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

try:
    import yaml
except ImportError:
    raise SystemExit("Missing dependency: pyyaml. Install with: uv add pyyaml")

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")
timeline_path = Path("runtime/history/timeline.json")
objective_path = Path("runtime/objective/objective.yaml")

required = [
    state_path,
    current_path,
    timeline_path,
    objective_path,
]

missing = [str(p) for p in required if not p.exists()]
if missing:
    raise SystemExit("Missing required Phase D files:\n" + "\n".join(missing))

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))
timeline = json.loads(timeline_path.read_text(encoding="utf-8"))
objective = yaml.safe_load(objective_path.read_text(encoding="utf-8"))

if state.get("phase") != "D":
    print(f"Phase D skipped. Current phase is {state.get('phase')}.")
    raise SystemExit(0)

exp_name = current.get("exp_name")
if not exp_name:
    state.update({
        "workflow_status": "blocked",
        "phase": "BLOCKED",
        "phase_step": "BLOCKED",
        "blocked": True,
        "block_reason": "Phase D requires current_iteration.exp_name",
        "updated_at": datetime.now(timezone.utc).isoformat(),
    })
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    raise SystemExit(state["block_reason"])

local_validation = current.get("local_validation", {})
if local_validation.get("status") != "passed" or not local_validation.get("passed"):
    state.update({
        "workflow_status": "blocked",
        "phase": "BLOCKED",
        "phase_step": "BLOCKED",
        "blocked": True,
        "block_reason": "Phase D requires passed local validation",
        "updated_at": datetime.now(timezone.utc).isoformat(),
    })
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    raise SystemExit(state["block_reason"])

remote_cfg = objective.get("remote_training", {}) or {}
enabled = bool(remote_cfg.get("enabled", False))

now = datetime.now(timezone.utc).isoformat()

print("== Phase D: Remote Training Launch ==")
print(f"exp_name: {exp_name}")
print(f"remote_training.enabled: {enabled}")

if not enabled:
    current["remote_training"] = {
        "status": "not_started",
        "server": None,
        "remote_dir": None,
        "train_command": None,
        "cron_id": None,
        "log_path": None,
        "started_at": None,
        "ended_at": now,
        "notes": [
            "Remote training was skipped because remote_training.enabled is false."
        ],
    }

    current.setdefault("local_validation", {}).setdefault("notes", []).append(
        f"{now}: Phase D skipped because remote_training.enabled is false."
    )

    current["updated_at"] = now

    timeline.setdefault("events", []).append({
        "time": now,
        "iteration": state.get("iteration", current.get("iteration", 0)),
        "exp_name": exp_name,
        "event_type": "phase_d_skipped",
        "phase": "D",
        "summary": "Remote training launch skipped because remote_training.enabled is false.",
        "best_val_loss": None,
        "is_new_best": False,
    })

    state.update({
        "workflow_status": "running",
        "phase": "E",
        "phase_step": "E1",
        "next_phase": "E",
        "blocked": False,
        "block_reason": None,
        "updated_at": now,
    })

    current_path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    timeline_path.write_text(json.dumps(timeline, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print("Phase D skipped. Advanced to Phase E/E1.")
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

missing_cfg = []
if not server:
    missing_cfg.append("remote_training.server")
if not remote_project_dir:
    missing_cfg.append("remote_training.remote_project_dir")
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
        "train_command": train_command_template.format(exp_name=exp_name),
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
        "event_type": "phase_d_failed",
        "phase": "D",
        "summary": reason,
        "best_val_loss": None,
        "is_new_best": False,
    })

    current_path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    timeline_path.write_text(json.dumps(timeline, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

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
    "server": server,
    "remote_dir": remote_project_dir,
    "train_command": train_command_template,
    "cron_id": None,
    "log_path": log_path_template,
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

current_path.write_text(json.dumps(current, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
timeline_path.write_text(json.dumps(timeline, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

print(reason)
raise SystemExit(1)
PY