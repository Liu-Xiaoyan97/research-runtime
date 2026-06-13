#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"

cd "$ROOT_DIR"

echo "== AutoResearch Schema Usage Validation =="
echo "ROOT_DIR=$ROOT_DIR"
echo "Using Python: $PYTHON_BIN"
echo

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "ERROR: Python binary not found or not executable: $PYTHON_BIN" >&2
  exit 1
fi

echo "== 1. Check required workflow schemas =="
required_workflow_schemas=(
  "workflow/oh-my-autoresearch/schemas/phase_b_agentteam_output.schema.json"
  "workflow/oh-my-autoresearch/schemas/experiment.schema.json"
)

for schema in "${required_workflow_schemas[@]}"; do
  if [[ ! -f "$schema" ]]; then
    echo "ERROR: missing workflow schema: $schema" >&2
    exit 1
  fi
  echo "OK: $schema"
done

echo

echo "== 2. Check required runtime schema snapshots =="
required_runtime_schemas=(
  "runtime/schemas/phase_b_agentteam_output.schema.json"
  "runtime/schemas/experiment.schema.json"
)

for schema in "${required_runtime_schemas[@]}"; do
  if [[ ! -f "$schema" ]]; then
    echo "ERROR: missing runtime schema snapshot: $schema" >&2
    echo "Hint: run:"
    echo "  python workflow/oh-my-autoresearch/scripts/install_runtime.py --root . --workflow-root workflow/oh-my-autoresearch"
    exit 1
  fi
  echo "OK: $schema"
done

echo

echo "== 3. Phase B schema negative/positive tests =="
"$PYTHON_BIN" - <<'PY'
from pathlib import Path
from scripts.schema_contract import load_schema, property_validator, validate_against_schema

root = Path(".").resolve()
schema = load_schema(root, "phase_b_agentteam_output.schema.json")

# Negative: modification_plan.status must be ready_for_implementation.
bad_plan = {
    "status": "draft",
    "selected_direction": "Test direction",
    "implementation_scope": ["project/nn-architecture"],
    "files_to_modify": ["project/nn-architecture/src/nn_architecture/model.py"],
    "local_validation_commands": ["python3 -m compileall ."],
    "notes": []
}

try:
    property_validator(schema, "modification_plan")(bad_plan)
except ValueError as exc:
    print("PASS: Phase B invalid modification_plan rejected:", exc)
else:
    raise SystemExit("FAIL: Phase B invalid modification_plan accepted")

# Positive: valid full Phase B AgentTeam output.
good_output = {
    "candidate_directions": [
        {
            "source": "flow-arch-reviewer",
            "title": "Add residual projection around TinyModel placeholder",
            "rationale": "Safe scaffold test candidate.",
            "implementation_hint": "Modify model.py.",
            "historical_overlap_risk": "low",
            "expected_risk": "low"
        }
    ],
    "deduplicated_directions": [
        {
            "title": "Add residual projection around TinyModel placeholder",
            "merged_from": ["flow-arch-reviewer"],
            "rationale": "Unique scaffold-safe candidate.",
            "implementation_hint": "Modify model.py.",
            "historical_overlap_risk": "low",
            "expected_risk": "low"
        }
    ],
    "selected_direction": {
        "title": "Add residual projection around TinyModel placeholder",
        "rationale": "Validates Phase C implementation path.",
        "expected_val_loss_effect": "unknown; scaffold-only",
        "risk": "low"
    },
    "modification_plan": {
        "status": "ready_for_implementation",
        "selected_direction": "Add residual projection around TinyModel placeholder",
        "implementation_scope": ["project/nn-architecture"],
        "files_to_modify": ["project/nn-architecture/src/nn_architecture/model.py"],
        "local_validation_commands": ["python3 -m compileall ."],
        "notes": ["schema positive test"]
    }
}

validate_against_schema(good_output, schema, "phase_b_agentteam_output")
print("PASS: Phase B valid AgentTeam output accepted")
PY
echo

echo "== 3b. Validate latest completed Phase B debate output against schema =="
"$PYTHON_BIN" - <<'PY'
import json
import re
from pathlib import Path

from scripts.schema_contract import load_schema, validate_against_schema

root = Path(".").resolve()
schema = load_schema(root, "phase_b_agentteam_output.schema.json")

current_path = root / "runtime/state/current_iteration.json"
current = json.loads(current_path.read_text(encoding="utf-8"))
exp_name = current.get("exp_name")

if not exp_name:
    print("WARN: current_iteration.json has no exp_name; skipping latest debate validation")
    raise SystemExit(0)

debate_path = root / "runtime/debates" / f"{exp_name}.md"
if not debate_path.is_file():
    print(f"WARN: missing debate file for current exp: {debate_path}; skipping")
    raise SystemExit(0)

text = debate_path.read_text(encoding="utf-8")

if "WAITING_FOR_AGENTTEAM" in text:
    print(f"WARN: {debate_path.name} is still WAITING_FOR_AGENTTEAM; skipping debate schema validation")
    raise SystemExit(0)

def section(name: str) -> str:
    pattern = rf"^## {re.escape(name)}\s*$([\s\S]*?)(?=^## |\Z)"
    match = re.search(pattern, text, flags=re.MULTILINE)
    if not match:
        raise ValueError(f"missing section: {name}")
    return match.group(1)

def first_json_block(section_text: str, section_name: str):
    match = re.search(r"```json[^\n]*\n([\s\S]*?)\n```", section_text)
    if not match:
        raise ValueError(f"missing json block in section: {section_name}")
    return json.loads(match.group(1))

candidate_directions = first_json_block(section("Candidate Directions"), "Candidate Directions")
deduplicated_directions = first_json_block(section("Deduplicated Directions"), "Deduplicated Directions")
selected_direction = first_json_block(section("Selected Direction"), "Selected Direction")
modification_plan = first_json_block(section("Modification Plan"), "Modification Plan")

if (
    candidate_directions == []
    or deduplicated_directions == []
    or selected_direction is None
    or modification_plan is None
):
    print(f"WARN: {debate_path.name} does not contain completed AgentTeam output; skipping debate schema validation")
    raise SystemExit(0)

output = {
    "candidate_directions": candidate_directions,
    "deduplicated_directions": deduplicated_directions,
    "selected_direction": selected_direction,
    "modification_plan": modification_plan,
}

validate_against_schema(output, schema, f"runtime/debates/{debate_path.name}")
print(f"PASS: latest completed Phase B debate output conforms to phase_b_agentteam_output.schema.json: {debate_path.name}")
PY

echo

echo "== 4. Phase E/F experiment schema negative/positive tests =="
"$PYTHON_BIN" - <<'PY'
from pathlib import Path
from scripts.schema_contract import load_schema, validate_against_schema

root = Path(".").resolve()
schema = load_schema(root, "experiment.schema.json")

base_experiment = {
    "exp_name": "exp_schema_test",
    "iteration": 999,
    "created_at": "2026-06-12T00:00:00+00:00",
    "status": "pending",
    "phase": "E",
    "objective_summary": "schema test",
    "selected_direction": "Add residual projection around TinyModel placeholder",
    "candidate_directions": [],
    "deduplicated_directions": [],
    "modification_plan": None,
    "code_change_summary": None,
    "local_validation": {
        "status": "passed",
        "commands": ["python3 -m compileall ."],
        "passed": True,
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
    "metrics": {
        "best_val_loss": None,
        "final_val_loss": None,
        "best_epoch": None,
        "loss_curve": []
    },
    "notes": []
}

validate_against_schema(base_experiment, schema, "experiment.phase_e")
print("PASS: Phase E valid experiment record accepted")

phase_f_experiment = dict(base_experiment)
phase_f_experiment["phase"] = "F"
phase_f_experiment["status"] = "succeeded"
phase_f_experiment["metrics"] = {
    "best_val_loss": 0.123,
    "final_val_loss": 0.150,
    "best_epoch": 7,
    "loss_curve": [
        {"epoch": 0, "val_loss": 0.300},
        {"epoch": 7, "val_loss": 0.123}
    ]
}

validate_against_schema(phase_f_experiment, schema, "experiment.phase_f")
print("PASS: Phase F valid experiment record accepted")

bad_experiment = dict(base_experiment)
bad_experiment["remote_training"] = {
    "status": "skipped"
}

try:
    validate_against_schema(bad_experiment, schema, "experiment.invalid_remote_status")
except ValueError as exc:
    print("PASS: invalid experiment remote_training.status rejected:", exc)
else:
    raise SystemExit("FAIL: invalid experiment remote_training.status accepted")
PY

echo

echo "== 5. Current iteration agent-team contract tests =="
"$PYTHON_BIN" - <<'PY'
import copy
import json
from pathlib import Path

from scripts.schema_contract import load_schema, validate_against_schema

root = Path(".").resolve()
schema = load_schema(root, "current_iteration.schema.json")
template_path = root / "workflow/oh-my-autoresearch/templates/nn_architecture/runtime/state/current_iteration.json"
template = json.loads(template_path.read_text(encoding="utf-8"))

validate_against_schema(template, schema, "current_iteration.template")
print("PASS: current_iteration template includes exact project-agent teams")

bad = copy.deepcopy(template)
bad["agentteam"]["b1_candidate_review"]["agents"] = [
    "math-theorist",
    "numerical-debugger",
    "flow-arch-reviewer",
]

try:
    validate_against_schema(bad, schema, "current_iteration.missing_team_leader")
except ValueError as exc:
    print("PASS: missing team-leader rejected:", exc)
else:
    raise SystemExit("FAIL: current_iteration accepted B1 agents without team-leader")

bad_f1 = copy.deepcopy(template)
bad_f1["agentteam"]["f1_evidence_review"]["agents"] = [
    "math-theorist",
    "numerical-debugger",
    "flow-arch-reviewer",
]

try:
    validate_against_schema(bad_f1, schema, "current_iteration.f1_missing_team_leader")
except ValueError as exc:
    print("PASS: F1 missing team-leader rejected:", exc)
else:
    raise SystemExit("FAIL: current_iteration accepted F1 agents without team-leader")
PY

echo

echo "== 6. Validate existing runtime experiment records =="
"$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path

from scripts.schema_contract import load_schema, validate_against_schema

root = Path(".").resolve()
schema = load_schema(root, "experiment.schema.json")
experiments_dir = root / "runtime/experiments"

if not experiments_dir.is_dir():
    raise SystemExit(f"ERROR: missing experiments directory: {experiments_dir}")

files = sorted(
    path for path in experiments_dir.glob("*.json")
    if path.name != "best.json"
    # *.metrics.json is the raw trainer output (written by train.py), not a
    # full experiment record; phase E consumes it to build the record. Do not
    # validate it against experiment.schema.json.
    and not path.name.endswith(".metrics.json")
)

if not files:
    print("WARN: no runtime experiment records found")
else:
    for path in files:
        data = json.loads(path.read_text(encoding="utf-8"))
        validate_against_schema(data, schema, f"runtime/experiments/{path.name}")
        print(f"PASS: {path.name} conforms to experiment.schema.json")
PY

echo

echo "== 7. Check phase scripts reference schema validation path =="
phase_b_refs=(
  "scripts/apply_agentteam_plan.py"
)

phase_ef_refs=(
  "scripts/phases/phase_d_remote_launch.sh"
  "scripts/phases/phase_e_monitoring.sh"
  "scripts/phases/phase_f_checkpoint.sh"
)

for file in "${phase_b_refs[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: missing file: $file" >&2
    exit 1
  fi

  if grep -Eq "phase_b_agentteam_output\\.schema\\.json|validate_against_schema|property_validator" "$file"; then
    echo "PASS: $file references Phase B schema validation"
  else
    echo "ERROR: $file does not appear to use Phase B schema validation" >&2
    exit 1
  fi
done

for file in "${phase_ef_refs[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: missing file: $file" >&2
    exit 1
  fi

  if grep -Eq "experiment\\.schema\\.json|validate_against_schema|validate_runtime" "$file"; then
    echo "PASS: $file references experiment/runtime schema validation"
  else
    echo "ERROR: $file does not appear to use experiment/runtime schema validation" >&2
    echo "Hint: add a validation call after writing experiment records."
    exit 1
  fi
done

if grep -Eq "workflow\\.config\\.json|workflow_config_path" scripts/phases/phase_d_remote_launch.sh \
  && grep -Eq "run_local_training|execution_mode.*local" scripts/phases/phase_d_remote_launch.sh \
  && grep -Eq "main_pid|subprocess\\.Popen" scripts/phases/phase_d_remote_launch.sh; then
  echo "PASS: scripts/phases/phase_d_remote_launch.sh runs local training when remote training is disabled"
else
  echo "ERROR: scripts/phases/phase_d_remote_launch.sh does not appear to bind workflow.config.json remote_training=false to background local training with main_pid" >&2
  exit 1
fi

if grep -Eq "crontab|install_monitor_cron" scripts/phases/phase_e_monitoring.sh \
  && grep -Eq "monitor_interval_minutes.*10|\\*/10" scripts/phases/phase_e_monitoring.sh \
  && grep -Eq "process_alive\\(|main_pid" scripts/phases/phase_e_monitoring.sh \
  && grep -Eq "cancel_monitor_cron|cron_cancelled" scripts/phases/phase_e_monitoring.sh; then
  echo "PASS: scripts/phases/phase_e_monitoring.sh creates 10-minute cron, checks main_pid first, and cancels cron on completion"
else
  echo "ERROR: scripts/phases/phase_e_monitoring.sh does not enforce cron-based main_pid-first monitoring" >&2
  exit 1
fi

echo

echo "== Schema usage validation passed =="
