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


def ensure_agentteam_contract(data):
    agentteam = data.setdefault("agentteam", {})
    if "f1_evidence_review" not in agentteam and "f2_evidence_review" in agentteam:
        agentteam["f1_evidence_review"] = agentteam.pop("f2_evidence_review")

    agentteam.setdefault("b1_candidate_review", {
        "status": "not_started",
        "summary": None,
        "candidate_count": 0,
        "blocking_issues": [],
    })
    agentteam["b1_candidate_review"]["agents"] = [
        "team-leader",
        "math-theorist",
        "numerical-debugger",
        "flow-arch-reviewer",
    ]
    agentteam["b1_candidate_review"].setdefault("team_lifecycle", {
        "required_agents": [
            "team-leader",
            "math-theorist",
            "numerical-debugger",
            "flow-arch-reviewer",
        ],
        "completed_agents": [],
        "all_agents_completed": False,
        "team_leader_finalized": False,
        "team_disbanded": False,
        "disbanded_at": None,
        "notes": [],
    })

    agentteam.setdefault("b2_orthogonality_review", {
        "status": "not_started",
        "agent": "orthogonal-direction-scout",
        "summary": None,
        "accepted_candidates": [],
        "rejected_candidates": [],
        "override_reason": None,
    })
    agentteam["b2_orthogonality_review"]["agent"] = "orthogonal-direction-scout"
    agentteam["b2_orthogonality_review"]["agents"] = [
        "team-leader",
        "orthogonal-direction-scout",
    ]
    agentteam["b2_orthogonality_review"].setdefault("team_lifecycle", {
        "required_agents": [
            "team-leader",
            "orthogonal-direction-scout",
        ],
        "completed_agents": [],
        "all_agents_completed": False,
        "team_leader_finalized": False,
        "team_disbanded": False,
        "disbanded_at": None,
        "notes": [],
    })

    agentteam.setdefault("b3_plan_selection", {
        "status": "not_started",
        "selected_candidate": None,
        "summary": None,
        "implementation_risks": [],
        "diagnostic_requirements": [],
    })
    agentteam["b3_plan_selection"]["agents"] = [
        "team-leader",
        "math-theorist",
        "numerical-debugger",
        "flow-arch-reviewer",
    ]
    agentteam["b3_plan_selection"].setdefault("team_lifecycle", {
        "required_agents": [
            "team-leader",
            "math-theorist",
            "numerical-debugger",
            "flow-arch-reviewer",
        ],
        "completed_agents": [],
        "all_agents_completed": False,
        "team_leader_finalized": False,
        "team_disbanded": False,
        "disbanded_at": None,
        "notes": [],
    })

    agentteam.setdefault("f1_evidence_review", {
        "status": "not_started",
        "summary": None,
        "verdict": None,
        "missing_evidence": [],
    })
    agentteam["f1_evidence_review"]["agents"] = [
        "team-leader",
        "math-theorist",
        "numerical-debugger",
        "flow-arch-reviewer",
    ]
    agentteam["f1_evidence_review"].setdefault("team_lifecycle", {
        "required_agents": [
            "team-leader",
            "math-theorist",
            "numerical-debugger",
            "flow-arch-reviewer",
        ],
        "completed_agents": [],
        "all_agents_completed": False,
        "team_leader_finalized": False,
        "team_disbanded": False,
        "disbanded_at": None,
        "notes": [],
    })
    data.setdefault("root_cause_analysis", {
        "status": "not_started",
        "agent_votes": [],
        "verdict": None,
        "summary": None,
    })


def team_section_complete(section, expected_agents):
    if not isinstance(section, dict):
        return False
    lifecycle = section.get("team_lifecycle")
    if not isinstance(lifecycle, dict):
        return False
    return (
        section.get("status") == "complete"
        and section.get("agents") == expected_agents
        and lifecycle.get("required_agents") == expected_agents
        and lifecycle.get("completed_agents") == expected_agents
        and lifecycle.get("all_agents_completed") is True
        and lifecycle.get("team_leader_finalized") is True
        and lifecycle.get("team_disbanded") is True
        and isinstance(lifecycle.get("disbanded_at"), str)
        and bool(lifecycle.get("disbanded_at"))
    )


ensure_agentteam_contract(current)

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

f1_review = current["agentteam"]["f1_evidence_review"]
root_cause = current["root_cause_analysis"]
f1_team_complete = team_section_complete(
    f1_review,
    ["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"],
)
if state.get("phase_step", "F1") == "F1" and (
    not f1_team_complete or root_cause.get("verdict") is None
):
    review_path = Path(f"runtime/debates/{exp_name}_f1_review.md")
    if not review_path.exists():
        current_schema_json = json.dumps(current_schema, indent=2, ensure_ascii=False)
        experiment_json = json.dumps(experiment, indent=2, ensure_ascii=False)
        current_json = json.dumps(current, indent=2, ensure_ascii=False)
        review_text = f"""# AgentTeam F1 Evidence Review: {exp_name}

## Status

WAITING_FOR_AGENTTEAM_F1

Claude must use the project agents in `.claude/agents/` and complete the F1
evidence review before Phase F writes checkpoints or learned/rejected knowledge.
The main Claude turn must not manually replace this review. Invoke the named
project agents and record their outputs before writing the F1 verdict.

## Required Project Agents (FLAT — no nesting)

The orchestrator (main turn) invokes the specialists DIRECTLY and IN PARALLEL,
then invokes `team-leader` only to reconcile. Do NOT invoke `team-leader` first
and let it spawn the specialists — that nesting is forbidden.

1. `math-theorist` (invoked by orchestrator)
2. `numerical-debugger` (invoked by orchestrator)
3. `flow-arch-reviewer` (invoked by orchestrator)
4. `team-leader` (invoked last; reconciles, does not spawn)

## Experiment Record

```json
{experiment_json}
```

## Current Iteration

```json
{current_json}
```

## Required Review

- `team-leader` reconciles the specialists' recorded outputs and records the
  final reconciliation. It does NOT spawn the specialists (no nesting).
- `math-theorist` decides whether the result supports or contradicts the original hypothesis.
- `numerical-debugger` checks whether metrics are trustworthy or contaminated by implementation, data, solver, or logging issues.
- `flow-arch-reviewer` decides whether the lesson is actionable and what the next research move should be.

## F1 Verdict

The `team-leader` must fill this machine-readable block. `apply_f1_review.py`
parses it and writes the verdict into runtime state. Do NOT hand-edit
`runtime/state/current_iteration.json` — the PreToolUse guard will block it.

```json
{{
  "verdict": "learned | rejected | inconclusive",
  "summary": "evidence-grounded reconciliation written by team-leader",
  "missing_evidence": [],
  "agent_votes": [
    {{"agent": "math-theorist", "verdict": "learned | rejected | inconclusive", "rationale": "..."}},
    {{"agent": "numerical-debugger", "verdict": "learned | rejected | inconclusive", "rationale": "..."}},
    {{"agent": "flow-arch-reviewer", "verdict": "learned | rejected | inconclusive", "rationale": "..."}}
  ]
}}
```

## Agent Team Execution Log

Record each F1 project agent's contribution — `team-leader`, `math-theorist`,
`numerical-debugger`, and `flow-arch-reviewer` — including minority objections
and the team-leader reconciliation. Every required agent MUST be named here;
`apply_f1_review.py` refuses to apply a verdict otherwise.

This review file may only be authored by the F1 project agents. The main Claude
turn must not write it. If agent output is missing or incomplete, WAIT and
re-invoke the agents — do not fabricate the review.

## Required Runtime Updates

Runtime state is script-owned. After the F1 agents fill the sections above, the
verdict reaches `runtime/state/current_iteration.json` ONLY through:

```bash
cd /Users/liuxiaoyan/workspace/research-runtime
./scripts/apply_f1_review.py
./scripts/run_loop.sh
```
"""
        review_path.write_text(review_text, encoding="utf-8")
        timeline.setdefault("events", []).append({
            "time": now,
            "iteration": state.get("iteration", current.get("iteration", 0)),
            "exp_name": exp_name,
            "event_type": "phase_f1_agentteam_prompt_created",
            "phase": "F",
            "summary": "Phase F/F1 created an AgentTeam evidence-review prompt and is waiting for structured review.",
            "best_val_loss": best_val_loss,
            "is_new_best": False,
        })
        write_json_with_schema(timeline_path, timeline, timeline_schema, str(timeline_path))

    f1_review["status"] = "in_progress"
    root_cause["status"] = "in_progress"
    current["updated_at"] = now
    write_json_with_schema(current_path, current, current_schema, str(current_path))
    state.update({
        "workflow_status": "running",
        "phase": "F",
        "phase_step": "F1",
        "next_phase": "F",
        "blocked": False,
        "block_reason": None,
        "updated_at": now,
    })
    write_json_with_schema(state_path, state, state_schema, str(state_path))

    print("== Phase F/F1: Waiting for AgentTeam Evidence Review ==")
    print(f"exp_name: {exp_name}")
    print(f"review_path: {review_path}")
    print("F1 requires every project agent to finish and the team-leader to finalize and disband the team.")
    print("Fill runtime/state/current_iteration.json with the F1 review, then rerun ./scripts/run_loop.sh.")
    raise SystemExit(0)

print("== Phase F: Checkpoint Write ==")
print(f"exp_name: {exp_name}")
print(f"has_real_result: {has_real_result}")
print(f"best_val_loss: {best_val_loss}")

review_verdict = root_cause.get("verdict") or f1_review.get("verdict")

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

    if review_verdict == "learned":
        learned_entry = f"""

## {exp_name}

- Date: {now}
- Iteration: {current.get("iteration", state.get("iteration"))}
- Selected direction: {current.get("selected_direction")}
- Best val_loss: {best_val_loss}
- Final val_loss: {final_val_loss}
- Best epoch: {best_epoch}
- New best: {is_new_best}
- Verdict: learned.
- Evidence: {root_cause.get("summary")}
- Modification summary: {current.get("code_change_summary")}
"""

        with learned_path.open("a", encoding="utf-8") as f:
            f.write(learned_entry)

        checkpoint_event_type = "phase_f_completed"
        checkpoint_summary = "F1 AgentTeam judged the experiment learned; checkpoint was written."
    elif review_verdict == "rejected":
        rejected_entry = f"""

## {exp_name}

- Date: {now}
- Iteration: {current.get("iteration", state.get("iteration"))}
- Selected direction: {current.get("selected_direction")}
- Best val_loss: {best_val_loss}
- Final val_loss: {final_val_loss}
- Best epoch: {best_epoch}
- New best: {is_new_best}
- Verdict: rejected.
- Rejection reason: {root_cause.get("summary")}
- Modification summary: {current.get("code_change_summary")}
"""

        with rejected_path.open("a", encoding="utf-8") as f:
            f.write(rejected_entry)

        checkpoint_event_type = "phase_f_rejected"
        checkpoint_summary = "F1 AgentTeam judged the experiment rejected; checkpoint was written."
    else:
        checkpoint_event_type = "phase_f_inconclusive"
        checkpoint_summary = "F1 AgentTeam judged the experiment inconclusive; checkpoint was written without learned/rejected update."

else:
    current.setdefault("result", {})
    current["result"].update({
        "status": "pending",
        "best_val_loss": None,
        "final_val_loss": None,
        "best_epoch": None,
        "is_new_best": False,
    })

    if review_verdict == "learned":
        learned_entry = f"""

## {exp_name}

- Date: {now}
- Iteration: {current.get("iteration", state.get("iteration"))}
- Selected direction: {current.get("selected_direction")}
- Verdict: learned.
- Evidence: {root_cause.get("summary")}
- Remote training status: {current.get("remote_training", {}).get("status")}
- Local validation status: {current.get("local_validation", {}).get("status")}
- Modification summary: {current.get("code_change_summary")}
"""

        with learned_path.open("a", encoding="utf-8") as f:
            f.write(learned_entry)

        checkpoint_event_type = "phase_f_completed"
        checkpoint_summary = "F1 AgentTeam judged the experiment learned despite missing primary metric."
    elif review_verdict == "rejected":
        rejected_entry = f"""

## {exp_name}

- Date: {now}
- Iteration: {current.get("iteration", state.get("iteration"))}
- Selected direction: {current.get("selected_direction")}
- Verdict: rejected.
- Rejection reason: {root_cause.get("summary")}
- Remote training status: {current.get("remote_training", {}).get("status")}
- Local validation status: {current.get("local_validation", {}).get("status")}
- Modification summary: {current.get("code_change_summary")}
"""

        with rejected_path.open("a", encoding="utf-8") as f:
            f.write(rejected_entry)

        checkpoint_event_type = "phase_f_no_real_result"
        checkpoint_summary = "F1 AgentTeam rejected the experiment after no real validation result."
    else:
        checkpoint_event_type = "phase_f_inconclusive"
        checkpoint_summary = "F1 AgentTeam judged the experiment inconclusive; no learned/rejected update was written."

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
    "agentteam": {
        "b1_candidate_review": {
            "status": "not_started",
            "agents": [
                "team-leader",
                "math-theorist",
                "numerical-debugger",
                "flow-arch-reviewer",
            ],
            "team_lifecycle": {
                "required_agents": [
                    "team-leader",
                    "math-theorist",
                    "numerical-debugger",
                    "flow-arch-reviewer",
                ],
                "completed_agents": [],
                "all_agents_completed": False,
                "team_leader_finalized": False,
                "team_disbanded": False,
                "disbanded_at": None,
                "notes": [],
            },
            "summary": None,
            "candidate_count": 0,
            "blocking_issues": [],
        },
        "b2_orthogonality_review": {
            "status": "not_started",
            "agent": "orthogonal-direction-scout",
            "agents": [
                "team-leader",
                "orthogonal-direction-scout",
            ],
            "team_lifecycle": {
                "required_agents": [
                    "team-leader",
                    "orthogonal-direction-scout",
                ],
                "completed_agents": [],
                "all_agents_completed": False,
                "team_leader_finalized": False,
                "team_disbanded": False,
                "disbanded_at": None,
                "notes": [],
            },
            "summary": None,
            "accepted_candidates": [],
            "rejected_candidates": [],
            "override_reason": None,
        },
        "b3_plan_selection": {
            "status": "not_started",
            "agents": [
                "team-leader",
                "math-theorist",
                "numerical-debugger",
                "flow-arch-reviewer",
            ],
            "team_lifecycle": {
                "required_agents": [
                    "team-leader",
                    "math-theorist",
                    "numerical-debugger",
                    "flow-arch-reviewer",
                ],
                "completed_agents": [],
                "all_agents_completed": False,
                "team_leader_finalized": False,
                "team_disbanded": False,
                "disbanded_at": None,
                "notes": [],
            },
            "selected_candidate": None,
            "summary": None,
            "implementation_risks": [],
            "diagnostic_requirements": [],
        },
        "f1_evidence_review": {
            "status": "not_started",
            "agents": [
                "team-leader",
                "math-theorist",
                "numerical-debugger",
                "flow-arch-reviewer",
            ],
            "team_lifecycle": {
                "required_agents": [
                    "team-leader",
                    "math-theorist",
                    "numerical-debugger",
                    "flow-arch-reviewer",
                ],
                "completed_agents": [],
                "all_agents_completed": False,
                "team_leader_finalized": False,
                "team_disbanded": False,
                "disbanded_at": None,
                "notes": [],
            },
            "summary": None,
            "verdict": None,
            "missing_evidence": [],
        },
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
