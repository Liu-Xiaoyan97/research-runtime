#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TARGET_DIRECTION = "Add residual projection around TinyModel placeholder"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def block_state(root: Path, reason: str) -> None:
    state_path = root / "runtime/state/state.json"
    state = load_json(state_path)

    now = datetime.now(timezone.utc).isoformat()
    state.update(
        {
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": now,
        }
    )

    write_json(state_path, state)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    current_path = root / "runtime/state/current_iteration.json"
    model_path = root / "project/nn-architecture/src/nn_architecture/model.py"

    if not current_path.exists():
        reason = f"Missing current iteration file: {current_path}"
        block_state(root, reason)
        raise SystemExit(reason)

    current = load_json(current_path)
    selected = current.get("selected_direction")

    if selected != TARGET_DIRECTION:
        print(f"Demo model change skipped. selected_direction={selected!r}")
        return 0

    if not model_path.exists():
        reason = f"Target demo model file not found: {model_path}"
        block_state(root, reason)
        raise SystemExit(reason)

    original = model_path.read_text(encoding="utf-8")

    marker = "# AutoResearch demo residual projection"
    if marker in original:
        print("Demo model change already applied. Skipping.")
        return 0

    if "class TinyModel:" not in original:
        reason = "Could not find TinyModel class in demo model file."
        block_state(root, reason)
        raise SystemExit(reason)

    replacement = '''class TinyModel:
    """Minimal placeholder model used only for AutoResearch runtime smoke tests."""

    def __init__(self, input_dim: int = 4, hidden_dim: int = 8, output_dim: int = 1):
        self.input_dim = input_dim
        self.hidden_dim = hidden_dim
        self.output_dim = output_dim

        # AutoResearch demo residual projection
        self.use_residual_projection = True
        self.residual_projection_dim = min(input_dim, output_dim)

    def describe(self) -> dict:
        return {
            "name": "TinyModel",
            "input_dim": self.input_dim,
            "hidden_dim": self.hidden_dim,
            "output_dim": self.output_dim,
            "use_residual_projection": self.use_residual_projection,
            "residual_projection_dim": self.residual_projection_dim,
        }
'''

    model_path.write_text(replacement, encoding="utf-8")

    now = datetime.now(timezone.utc).isoformat()
    current["code_change_summary"] = (
        "Applied demo residual-projection metadata change to "
        "project/nn-architecture/src/nn_architecture/model.py"
    )
    current.setdefault("local_validation", {}).setdefault("notes", []).append(
        f"{now}: apply_demo_model_change.py modified demo TinyModel."
    )
    current["updated_at"] = now

    write_json(current_path, current)

    print(f"Applied demo model change: {model_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())