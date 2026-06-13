#!/usr/bin/env python3
import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.schema_contract import load_schema, property_validator, validate_against_schema

def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

def load_training_entrypoint(root: Path) -> dict[str, Any]:
    path = root / "runtime/training/entrypoint.yaml"
    if not path.exists():
        raise SystemExit(f"Missing training entrypoint: {path}")

    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"Invalid training entrypoint: {path}")

    local = data.get("local")
    if not isinstance(local, dict):
        raise SystemExit("training entrypoint missing local section")

    command = local.get("command")
    if not isinstance(command, str) or not command.strip():
        raise SystemExit("training entrypoint local.command must be a non-empty string")

    return data


def render_training_command(template: str, exp_name: str) -> str:
    return template.format(exp_name=exp_name)


def open_team_lifecycle(required_agents: list[str]) -> dict[str, Any]:
    return {
        "required_agents": required_agents,
        "completed_agents": [],
        "all_agents_completed": False,
        "team_leader_finalized": False,
        "team_disbanded": False,
        "disbanded_at": None,
        "notes": [],
    }


def closed_team_lifecycle(required_agents: list[str], timestamp: str, note: str) -> dict[str, Any]:
    return {
        "required_agents": required_agents,
        "completed_agents": required_agents,
        "all_agents_completed": True,
        "team_leader_finalized": True,
        "team_disbanded": True,
        "disbanded_at": timestamp,
        "notes": [note],
    }


def ensure_agentteam_contract(current: dict[str, Any]) -> dict[str, Any]:
    agentteam = current.setdefault("agentteam", {})
    if "f1_evidence_review" not in agentteam and "f2_evidence_review" in agentteam:
        agentteam["f1_evidence_review"] = agentteam.pop("f2_evidence_review")

    agentteam.setdefault("b1_candidate_review", {})
    agentteam["b1_candidate_review"].update({
        "agents": ["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"],
    })
    agentteam["b1_candidate_review"].setdefault(
        "team_lifecycle",
        open_team_lifecycle(["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"]),
    )

    agentteam.setdefault("b2_orthogonality_review", {})
    agentteam["b2_orthogonality_review"].update({
        "agent": "orthogonal-direction-scout",
        "agents": ["team-leader", "orthogonal-direction-scout"],
    })
    agentteam["b2_orthogonality_review"].setdefault(
        "team_lifecycle",
        open_team_lifecycle(["team-leader", "orthogonal-direction-scout"]),
    )

    agentteam.setdefault("b3_plan_selection", {})
    agentteam["b3_plan_selection"].update({
        "agents": ["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"],
    })
    agentteam["b3_plan_selection"].setdefault(
        "team_lifecycle",
        open_team_lifecycle(["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"]),
    )

    agentteam.setdefault("f1_evidence_review", {})
    agentteam["f1_evidence_review"].update({
        "status": agentteam["f1_evidence_review"].get("status", "not_started"),
        "agents": ["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"],
        "team_lifecycle": agentteam["f1_evidence_review"].get(
            "team_lifecycle",
            open_team_lifecycle(["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"]),
        ),
        "summary": agentteam["f1_evidence_review"].get("summary"),
        "verdict": agentteam["f1_evidence_review"].get("verdict"),
        "missing_evidence": agentteam["f1_evidence_review"].get("missing_evidence", []),
    })

    return agentteam


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


B_REQUIRED_AGENTS = [
    "team-leader",
    "math-theorist",
    "numerical-debugger",
    "flow-arch-reviewer",
    "orthogonal-direction-scout",
]


def require_execution_log(text: str) -> None:
    """Structural anti-fabrication gate for Phase B.

    The agent-authored debate file must contain an "Agent Team Execution Log"
    that names every required B1/B2/B3 agent. Combined with the PreToolUse guard
    (only project agents may author runtime/debates/**, never the main turn),
    this makes it materially harder to fabricate a debate instead of running the
    real AgentTeam.
    """
    try:
        log_section = extract_section(text, "Agent Team Execution Log")
    except ValueError as exc:
        raise SystemExit(
            "Debate file is missing the '## Agent Team Execution Log' section. "
            "The team-leader must record which project agents ran for B1, B2, and "
            "B3 before the plan can be applied. Do NOT fabricate this — invoke the "
            "project agents."
        ) from exc

    lowered = log_section.lower()
    missing = [agent for agent in B_REQUIRED_AGENTS if agent.lower() not in lowered]
    if missing:
        raise SystemExit(
            "Agent Team Execution Log does not reference required agents: "
            + ", ".join(missing)
            + ". Every B1/B2/B3 project agent must be recorded. If their output is "
            "missing, wait and re-invoke them — do not fabricate."
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
    require_execution_log(text)
    phase_b_schema = load_schema(root, "phase_b_agentteam_output.schema.json")

    candidate_directions = extract_matching_json_block(
        extract_section(text, "Candidate Directions"),
        "Candidate Directions",
        property_validator(phase_b_schema, "candidate_directions"),
    )

    deduplicated_directions = extract_matching_json_block(
        extract_section(text, "Deduplicated Directions"),
        "Deduplicated Directions",
        property_validator(phase_b_schema, "deduplicated_directions"),
    )

    selected_direction = extract_matching_json_block(
        extract_section(text, "Selected Direction"),
        "Selected Direction",
        property_validator(phase_b_schema, "selected_direction"),
    )
    validate_selected_direction(selected_direction)

    modification_plan = extract_matching_json_block(
        extract_section(text, "Modification Plan"),
        "Modification Plan",
        property_validator(phase_b_schema, "modification_plan"),
    )
    
    validate_modification_plan(modification_plan)
    
    training_entrypoint = load_training_entrypoint(root)
    local = training_entrypoint["local"]

    training_command = render_training_command(
        local["command"],
        exp_name=exp_name,
    )

    modification_plan["local_validation_commands"] = [training_command]
    modification_plan["training_entrypoint"] = {
        "project_dir": training_entrypoint.get("project_dir", "project/nn-architecture"),
        "metrics_file": local.get("metrics_file", "").format(exp_name=exp_name),
    }

    phase_b_agentteam_output = {
        "candidate_directions": candidate_directions,
        "deduplicated_directions": deduplicated_directions,
        "selected_direction": selected_direction,
        "modification_plan": modification_plan,
    }

    validate_against_schema(
        phase_b_agentteam_output,
        phase_b_schema,
        "phase_b_agentteam_output",
    )

    selected_title = selected_direction["title"]
    commands = modification_plan["local_validation_commands"]
    now = datetime.now(timezone.utc).isoformat()
    agentteam = ensure_agentteam_contract(current)
    agentteam["b1_candidate_review"].update({
        "status": "complete",
        "summary": "B1 project agents generated and stress-tested candidate directions.",
        "team_lifecycle": closed_team_lifecycle(
            ["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"],
            now,
            "B1 project-agent team completed, team-leader finalized, and team was disbanded.",
        ),
        "candidate_count": len(candidate_directions),
        "blocking_issues": [],
    })
    agentteam["b2_orthogonality_review"].update({
        "status": "complete",
        "summary": "B2 project agents reviewed candidate orthogonality against runtime history.",
        "team_lifecycle": closed_team_lifecycle(
            ["team-leader", "orthogonal-direction-scout"],
            now,
            "B2 project-agent team completed, team-leader finalized, and team was disbanded.",
        ),
        "accepted_candidates": [
            item.get("title", item.get("id", "unknown"))
            for item in deduplicated_directions
            if isinstance(item, dict)
        ],
        "rejected_candidates": [],
        "override_reason": None,
    })
    agentteam["b3_plan_selection"].update({
        "status": "complete",
        "selected_candidate": selected_title,
        "summary": "B3 project agents selected one concrete Phase C implementation plan.",
        "team_lifecycle": closed_team_lifecycle(
            ["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"],
            now,
            "B3 project-agent team completed, team-leader finalized, and team was disbanded.",
        ),
        "implementation_risks": modification_plan.get("implementation_risks", []),
        "diagnostic_requirements": modification_plan.get("diagnostic_requirements", []),
    })

    current.update(
        {
            "candidate_directions": candidate_directions,
            "deduplicated_directions": deduplicated_directions,
            "selected_direction": selected_title,
            "selected_direction_detail": selected_direction,
            "phase_b_agentteam_output": phase_b_agentteam_output,
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
            "agentteam": agentteam,
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
