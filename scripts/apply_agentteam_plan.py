#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def extract_section(text: str, heading: str) -> str:
    pattern = rf"^## {re.escape(heading)}\s*$([\s\S]*?)(?=^## |\Z)"
    match = re.search(pattern, text, flags=re.MULTILINE)
    if not match:
        raise ValueError(f"Missing section: ## {heading}")
    return match.group(1).strip()


def extract_json_blocks(section: str, heading: str) -> list[Any]:
    # Accept both:
    # ```json
    # {...}
    # ```
    #
    # and accidentally captured variants where the raw block starts with "json\n".
    blocks = re.findall(
        r"```(?:json)?[^\n]*\n([\s\S]*?)\n```",
        section,
        flags=re.MULTILINE,
    )

    if not blocks:
        raise ValueError(f"Missing JSON code block in section: {heading}")

    parsed: list[Any] = []
    errors: list[str] = []

    for idx, raw in enumerate(blocks):
        raw = raw.strip()

        # Defensive cleanup for malformed regex captures or manually copied fences.
        if raw.startswith("json\n"):
            raw = raw.split("\n", 1)[1].strip()
        elif raw == "json":
            raw = ""

        if not raw:
            errors.append(f"block {idx}: empty")
            continue

        try:
            parsed.append(json.loads(raw))
        except json.JSONDecodeError as exc:
            preview = raw[:120].replace("\n", "\\n")
            errors.append(f"block {idx}: {exc}; preview={preview!r}")

    if not parsed:
        raise ValueError(
            f"No valid JSON block found in section {heading}. Errors: {'; '.join(errors)}"
        )

    return parsed


def extract_matching_json_block(section: str, heading: str, validator) -> Any:
    values = extract_json_blocks(section, heading)
    errors: list[str] = []

    for idx, value in enumerate(values):
        try:
            return validator(value)
        except ValueError as exc:
            errors.append(f"block {idx}: {exc}")

    raise ValueError(
        f"No JSON block in section {heading} matched expected schema. "
        f"Errors: {'; '.join(errors)}"
    )


def validate_candidate_directions(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise ValueError("Candidate Directions must be a JSON list")
    for idx, item in enumerate(value):
        if not isinstance(item, dict):
            raise ValueError(f"Candidate Directions item {idx} must be an object")
        for key in ["source", "title", "rationale"]:
            if not item.get(key):
                raise ValueError(f"Candidate Directions item {idx} missing {key}")
    return value


def validate_deduplicated_directions(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        raise ValueError("Deduplicated Directions must be a JSON list")
    for idx, item in enumerate(value):
        if not isinstance(item, dict):
            raise ValueError(f"Deduplicated Directions item {idx} must be an object")
        if not item.get("title"):
            raise ValueError(f"Deduplicated Directions item {idx} missing title")
    return value


def validate_selected_direction(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("Selected Direction must be a JSON object")
    if not value.get("title"):
        raise ValueError("Selected Direction missing title")
    return value


def validate_modification_plan(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("Modification Plan must be a JSON object")

    if value.get("status") != "ready_for_implementation":
        raise ValueError("Modification Plan status must be ready_for_implementation")

    if not value.get("selected_direction"):
        raise ValueError("Modification Plan missing selected_direction")

    scope = value.get("implementation_scope")
    if not isinstance(scope, list) or not scope:
        raise ValueError("Modification Plan implementation_scope must be a non-empty list")

    commands = value.get("local_validation_commands")
    if not isinstance(commands, list) or not commands:
        raise ValueError("Modification Plan local_validation_commands must be a non-empty list")

    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        default=".",
        help="Path to autoresearch-runtime root",
    )
    parser.add_argument(
        "--exp-name",
        default=None,
        help="Experiment name. Defaults to current_iteration.exp_name",
    )
    parser.add_argument(
        "--advance",
        action="store_true",
        help="Advance workflow state to C/C1 after applying the plan",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()

    state_path = root / "runtime/state/state.json"
    current_path = root / "runtime/state/current_iteration.json"
    timeline_path = root / "runtime/history/timeline.json"

    state = load_json(state_path)
    current = load_json(current_path)
    timeline = load_json(timeline_path)

    exp_name = args.exp_name or current.get("exp_name")
    if not exp_name:
        raise SystemExit("Missing exp_name. Provide --exp-name or set current_iteration.exp_name.")

    debate_path = root / f"runtime/debates/{exp_name}.md"
    if not debate_path.exists():
        raise SystemExit(f"Debate file not found: {debate_path}")

    text = debate_path.read_text(encoding="utf-8")

    candidate_directions = extract_matching_json_block(
        extract_section(text, "Candidate Directions"),
        "Candidate Directions",
        validate_candidate_directions,
    )

    deduplicated_directions = extract_matching_json_block(
        extract_section(text, "Deduplicated Directions"),
        "Deduplicated Directions",
        validate_deduplicated_directions,
    )
    
    selected_direction = extract_matching_json_block(
        extract_section(text, "Selected Direction"),
        "Selected Direction",
        validate_selected_direction,
    )

    modification_plan = extract_matching_json_block(
        extract_section(text, "Modification Plan"),
        "Modification Plan",
        validate_modification_plan,
    )

    selected_title = selected_direction["title"]
    commands = modification_plan["local_validation_commands"]
    now = datetime.now(timezone.utc).isoformat()

    current.update(
        {
            "candidate_directions": candidate_directions,
            "deduplicated_directions": deduplicated_directions,
            "selected_direction": selected_title,
            "modification_plan": json.dumps(
                modification_plan,
                indent=2,
                ensure_ascii=False,
            ),
            "local_validation": {
                "status": "not_started",
                "commands": commands,
                "passed": False,
                "notes": [
                    f"{now}: AgentTeam plan applied from {debate_path.relative_to(root)}"
                ],
            },
            "updated_at": now,
        }
    )

    timeline.setdefault("events", []).append(
        {
            "time": now,
            "iteration": current.get("iteration", state.get("iteration")),
            "exp_name": exp_name,
            "event_type": "agentteam_plan_applied",
            "phase": "B",
            "summary": f"AgentTeam plan applied. Selected direction: {selected_title}",
            "best_val_loss": None,
            "is_new_best": False,
        }
    )

    if args.advance:
        state.update(
            {
                "workflow_status": "running",
                "phase": "C",
                "phase_step": "C1",
                "next_phase": "C",
                "blocked": False,
                "block_reason": None,
                "updated_at": now,
            }
        )

    write_json(current_path, current)
    write_json(timeline_path, timeline)
    write_json(state_path, state)

    print(f"Applied AgentTeam plan from: {debate_path}")
    print(f"Selected direction: {selected_title}")
    if args.advance:
        print("Advanced workflow to Phase C/C1.")
    else:
        print("Workflow phase unchanged. Use --advance to move to C/C1.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())