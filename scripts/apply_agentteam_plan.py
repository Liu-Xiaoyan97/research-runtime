#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PHASE_B_SCHEMA = "workflow/oh-my-autoresearch/schemas/phase_b_agentteam_output.schema.json"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def load_phase_b_schema(root: Path) -> dict[str, Any]:
    schema_path = root / PHASE_B_SCHEMA
    try:
        schema = load_json(schema_path)
    except FileNotFoundError as exc:
        raise SystemExit(f"Missing Phase B schema: {schema_path}") from exc

    if not isinstance(schema.get("properties"), dict):
        raise SystemExit(f"Invalid Phase B schema: missing properties in {schema_path}")

    return schema


def phase_b_property_validator(schema: dict[str, Any], property_name: str):
    properties = schema.get("properties", {})
    if property_name not in properties:
        raise SystemExit(f"Invalid Phase B schema: missing property {property_name}")

    def validator(value: Any) -> Any:
        validate_json_schema(value, properties[property_name], schema, property_name)
        return value

    return validator


def validate_json_schema(
    value: Any,
    schema: dict[str, Any],
    root_schema: dict[str, Any],
    location: str,
) -> None:
    if "$ref" in schema:
        schema = resolve_schema_ref(schema["$ref"], root_schema)

    expected_type = schema.get("type")
    if expected_type is not None and not matches_schema_type(value, expected_type):
        raise ValueError(f"{location} must be {format_schema_type(expected_type)}")

    if "const" in schema and value != schema["const"]:
        raise ValueError(f"{location} must be {schema['const']!r}")

    if "enum" in schema and value not in schema["enum"]:
        raise ValueError(f"{location} must be one of {schema['enum']!r}")

    if isinstance(value, str) and "minLength" in schema and len(value) < schema["minLength"]:
        raise ValueError(f"{location} must have length >= {schema['minLength']}")

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            raise ValueError(f"{location} must have at least {schema['minItems']} items")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for idx, item in enumerate(value):
                validate_json_schema(item, item_schema, root_schema, f"{location}[{idx}]")

    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                raise ValueError(f"{location} missing {key}")

        properties = schema.get("properties", {})
        if isinstance(properties, dict):
            for key, child_value in value.items():
                child_schema = properties.get(key)
                if isinstance(child_schema, dict):
                    validate_json_schema(child_value, child_schema, root_schema, f"{location}.{key}")
                elif schema.get("additionalProperties") is False:
                    raise ValueError(f"{location} has unexpected property {key}")


def resolve_schema_ref(ref: str, root_schema: dict[str, Any]) -> dict[str, Any]:
    if not ref.startswith("#/"):
        raise ValueError(f"Unsupported schema ref: {ref}")

    node: Any = root_schema
    for part in ref[2:].split("/"):
        if not isinstance(node, dict) or part not in node:
            raise ValueError(f"Unresolved schema ref: {ref}")
        node = node[part]

    if not isinstance(node, dict):
        raise ValueError(f"Schema ref does not point to an object: {ref}")
    return node


def matches_schema_type(value: Any, expected_type: str | list[str]) -> bool:
    if isinstance(expected_type, list):
        return any(matches_schema_type(value, item) for item in expected_type)

    if expected_type == "object":
        return isinstance(value, dict)
    if expected_type == "array":
        return isinstance(value, list)
    if expected_type == "string":
        return isinstance(value, str)
    if expected_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected_type == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected_type == "boolean":
        return isinstance(value, bool)
    if expected_type == "null":
        return value is None
    raise ValueError(f"Unsupported schema type: {expected_type}")


def format_schema_type(expected_type: str | list[str]) -> str:
    if isinstance(expected_type, list):
        return " or ".join(expected_type)
    return expected_type


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

    title = value.get("title")
    if not title:
        raise ValueError("Selected Direction missing title")

    forbidden_titles = {
        "selected direction",
        "selected direction title",
        "short direction name",
    }

    if str(title).strip().lower() in forbidden_titles:
        raise ValueError(f"Selected Direction appears to be a schema placeholder: {title!r}")

    return value


def validate_modification_plan(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("Modification Plan must be a JSON object")

    if value.get("status") != "ready_for_implementation":
        raise ValueError("Modification Plan status must be ready_for_implementation")

    selected_direction = value.get("selected_direction")
    if not selected_direction:
        raise ValueError("Modification Plan missing selected_direction")

    forbidden_selected = {
        "selected direction",
        "selected direction title",
        "short direction name",
    }

    if str(selected_direction).strip().lower() in forbidden_selected:
        raise ValueError(
            f"Modification Plan selected_direction appears to be a schema placeholder: {selected_direction!r}"
        )

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
    phase_b_schema = load_phase_b_schema(root)

    candidate_directions = extract_matching_json_block(
        extract_section(text, "Candidate Directions"),
        "Candidate Directions",
        phase_b_property_validator(phase_b_schema, "candidate_directions"),
    )

    deduplicated_directions = extract_matching_json_block(
        extract_section(text, "Deduplicated Directions"),
        "Deduplicated Directions",
        phase_b_property_validator(phase_b_schema, "deduplicated_directions"),
    )

    selected_direction = extract_matching_json_block(
        extract_section(text, "Selected Direction"),
        "Selected Direction",
        phase_b_property_validator(phase_b_schema, "selected_direction"),
    )
    validate_selected_direction(selected_direction)

    modification_plan = extract_matching_json_block(
        extract_section(text, "Modification Plan"),
        "Modification Plan",
        phase_b_property_validator(phase_b_schema, "modification_plan"),
    )
    validate_modification_plan(modification_plan)

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
