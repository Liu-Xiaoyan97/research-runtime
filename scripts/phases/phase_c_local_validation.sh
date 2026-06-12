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
from __future__ import annotations

import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(".").resolve()

STATE_PATH = ROOT / "runtime/state/state.json"
CURRENT_PATH = ROOT / "runtime/state/current_iteration.json"
TIMELINE_PATH = ROOT / "runtime/history/timeline.json"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def load_required_files() -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    missing = [
        str(path.relative_to(ROOT))
        for path in [STATE_PATH, CURRENT_PATH, TIMELINE_PATH]
        if not path.exists()
    ]

    if missing:
        state = load_json(STATE_PATH) if STATE_PATH.exists() else {}
        block_state(
            state=state,
            current=None,
            timeline=None,
            reason="Missing required Phase C files: " + ", ".join(missing),
            event_type="phase_c_failed",
        )
        raise SystemExit(1)

    return load_json(STATE_PATH), load_json(CURRENT_PATH), load_json(TIMELINE_PATH)


def parse_modification_plan(current: dict[str, Any]) -> dict[str, Any]:
    raw = current.get("modification_plan")

    if raw is None:
        raise ValueError("Phase C requires current_iteration.modification_plan")

    if isinstance(raw, dict):
        return raw

    if isinstance(raw, str):
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError(f"current_iteration.modification_plan is not valid JSON: {exc}") from exc

        if not isinstance(data, dict):
            raise ValueError("current_iteration.modification_plan must decode to an object")

        return data

    raise ValueError("current_iteration.modification_plan must be an object or JSON string")


def get_project_dir(current: dict[str, Any], plan: dict[str, Any]) -> Path:
    entrypoint = plan.get("training_entrypoint")
    if isinstance(entrypoint, dict):
        project_dir = entrypoint.get("project_dir")
        if isinstance(project_dir, str) and project_dir.strip():
            return ROOT / project_dir

    scope = plan.get("implementation_scope")
    if isinstance(scope, list):
        for item in scope:
            if isinstance(item, str) and item.startswith("project/"):
                return ROOT / item

    return ROOT / "project/nn-architecture"


def get_commands(current: dict[str, Any]) -> list[str]:
    local_validation = current.get("local_validation")
    if not isinstance(local_validation, dict):
        raise ValueError("Phase C requires current_iteration.local_validation object")

    commands = local_validation.get("commands")
    if not isinstance(commands, list) or not commands:
        raise ValueError("Phase C requires current_iteration.local_validation.commands to be a non-empty list")

    normalized: list[str] = []
    for idx, command in enumerate(commands):
        if not isinstance(command, str) or not command.strip():
            raise ValueError(f"current_iteration.local_validation.commands[{idx}] must be a non-empty string")
        normalized.append(command.strip())

    return normalized


def append_timeline(
    timeline: dict[str, Any],
    state: dict[str, Any],
    current: dict[str, Any],
    *,
    event_type: str,
    summary: str,
) -> None:
    timeline.setdefault("events", []).append(
        {
            "time": now_iso(),
            "iteration": state.get("iteration", current.get("iteration", 0)),
            "exp_name": current.get("exp_name"),
            "event_type": event_type,
            "phase": "C",
            "summary": summary,
            "best_val_loss": None,
            "is_new_best": False,
        }
    )


def block_state(
    *,
    state: dict[str, Any],
    current: dict[str, Any] | None,
    timeline: dict[str, Any] | None,
    reason: str,
    event_type: str,
) -> None:
    timestamp = now_iso()

    state.update(
        {
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": timestamp,
        }
    )

    if current is not None:
        current.setdefault("local_validation", {})
        current["local_validation"]["status"] = "failed"
        current["local_validation"]["passed"] = False
        current["local_validation"].setdefault("notes", []).append(f"{timestamp}: {reason}")
        current["updated_at"] = timestamp

    if timeline is not None and current is not None:
        append_timeline(
            timeline,
            state,
            current,
            event_type=event_type,
            summary=reason,
        )

    if STATE_PATH.exists():
        write_json(STATE_PATH, state)
    if current is not None:
        write_json(CURRENT_PATH, current)
    if timeline is not None:
        write_json(TIMELINE_PATH, timeline)

    print(reason)


def mark_phase_c_started(current: dict[str, Any]) -> None:
    timestamp = now_iso()
    current.setdefault("local_validation", {})
    current["local_validation"]["status"] = "not_started"
    current["local_validation"]["passed"] = False
    current["local_validation"].setdefault("notes", []).append(
        f"{timestamp}: Phase C started. Running current_iteration.local_validation.commands locally."
    )
    current["updated_at"] = timestamp


def run_commands(commands: list[str], project_dir: Path) -> tuple[bool, list[str]]:
    notes: list[str] = []

    for command in commands:
        rel_project_dir = project_dir.relative_to(ROOT) if project_dir.is_relative_to(ROOT) else project_dir
        print(f"+ cd {rel_project_dir} && {command}", flush=True)

        completed = subprocess.run(
            command,
            cwd=project_dir,
            shell=True,
            text=True,
        )

        if completed.returncode != 0:
            note = f"Command failed with exit code {completed.returncode}: {command}"
            notes.append(note)
            return False, notes

        notes.append(f"Command passed: {command}")

    return True, notes


def main() -> int:
    state, current, timeline = load_required_files()

    if state.get("phase") != "C":
        print(f"Phase C skipped. Current phase is {state.get('phase')}.")
        return 0

    exp_name = current.get("exp_name")
    if not exp_name:
        block_state(
            state=state,
            current=current,
            timeline=timeline,
            reason="Phase C requires current_iteration.exp_name",
            event_type="phase_c_failed",
        )
        return 1

    try:
        plan = parse_modification_plan(current)
        commands = get_commands(current)
        project_dir = get_project_dir(current, plan)
    except ValueError as exc:
        block_state(
            state=state,
            current=current,
            timeline=timeline,
            reason=str(exc),
            event_type="phase_c_failed",
        )
        return 1

    if not project_dir.is_dir():
        block_state(
            state=state,
            current=current,
            timeline=timeline,
            reason=f"Project directory not found: {project_dir.relative_to(ROOT) if project_dir.is_relative_to(ROOT) else project_dir}",
            event_type="phase_c_failed",
        )
        return 1

    print("== Phase C: Implementation and Local Validation ==")
    print(f"exp_name: {exp_name}")
    print(f"project_dir: {project_dir.relative_to(ROOT) if project_dir.is_relative_to(ROOT) else project_dir}")
    print("Using current_iteration.local_validation.commands")

    mark_phase_c_started(current)
    write_json(CURRENT_PATH, current)

    passed, command_notes = run_commands(commands, project_dir)

    timestamp = now_iso()
    current["local_validation"]["status"] = "passed" if passed else "failed"
    current["local_validation"]["passed"] = passed
    current["local_validation"].setdefault("notes", []).extend(
        f"{timestamp}: {note}" for note in command_notes
    )

    if not current.get("code_change_summary"):
        current["code_change_summary"] = "Phase C executed current_iteration.local_validation.commands."

    current["updated_at"] = timestamp

    if passed:
        state.update(
            {
                "workflow_status": "running",
                "phase": "D",
                "phase_step": "D1",
                "next_phase": "D",
                "blocked": False,
                "block_reason": None,
                "updated_at": timestamp,
            }
        )

        append_timeline(
            timeline,
            state,
            current,
            event_type="phase_c_completed",
            summary="Local validation commands passed. Workflow advanced to Phase D.",
        )

        write_json(STATE_PATH, state)
        write_json(CURRENT_PATH, current)
        write_json(TIMELINE_PATH, timeline)

        print("Phase C completed. Advanced to Phase D/D1.")
        return 0

    reason = command_notes[-1] if command_notes else "Phase C local validation command failed"

    state.update(
        {
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": timestamp,
        }
    )

    append_timeline(
        timeline,
        state,
        current,
        event_type="phase_c_failed",
        summary=reason,
    )

    write_json(STATE_PATH, state)
    write_json(CURRENT_PATH, current)
    write_json(TIMELINE_PATH, timeline)

    print("Phase C failed. Workflow moved to BLOCKED.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
PY