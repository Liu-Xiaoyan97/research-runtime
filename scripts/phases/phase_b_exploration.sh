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

required = [
    "runtime/objective/objective.yaml",
    "runtime/state/state.json",
    "runtime/state/current_iteration.json",
    "runtime/state/val_loss.json",
    "runtime/knowledge/learned_patterns.md",
    "runtime/knowledge/rejected_ideas.md",
    "runtime/history/timeline.json",
    "runtime/experiments/best.json",
    "workflow/oh-my-autoresearch/schemas/phase_b_agentteam_output.schema.json",
]

missing = [p for p in required if not Path(p).exists()]
if missing:
    raise SystemExit("Missing required Phase B files:\n" + "\n".join(missing))

state_path = Path("runtime/state/state.json")
current_path = Path("runtime/state/current_iteration.json")
timeline_path = Path("runtime/history/timeline.json")

state = json.loads(state_path.read_text(encoding="utf-8"))
current = json.loads(current_path.read_text(encoding="utf-8"))
timeline = json.loads(timeline_path.read_text(encoding="utf-8"))

if state.get("phase") != "B":
    print(f"Phase B skipped. Current phase is {state.get('phase')}.")
    raise SystemExit(0)

objective = yaml.safe_load(Path("runtime/objective/objective.yaml").read_text(encoding="utf-8"))
val_loss = json.loads(Path("runtime/state/val_loss.json").read_text(encoding="utf-8"))
best = json.loads(Path("runtime/experiments/best.json").read_text(encoding="utf-8"))
learned = Path("runtime/knowledge/learned_patterns.md").read_text(encoding="utf-8")
rejected = Path("runtime/knowledge/rejected_ideas.md").read_text(encoding="utf-8")

phase_step = state.get("phase_step", "B1")
now = datetime.now(timezone.utc).isoformat()

B1_B3_AGENTS = ["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"]
B2_AGENTS = ["team-leader", "orthogonal-direction-scout"]


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


def phase_b_team_complete(current_iteration):
    agentteam = current_iteration.get("agentteam")
    if not isinstance(agentteam, dict):
        return False
    return (
        team_section_complete(agentteam.get("b1_candidate_review"), B1_B3_AGENTS)
        and team_section_complete(agentteam.get("b2_orthogonality_review"), B2_AGENTS)
        and team_section_complete(agentteam.get("b3_plan_selection"), B1_B3_AGENTS)
    )

if phase_step == "B1":
    next_iteration = int(state.get("iteration", 0)) + 1
    exp_name = f"exp_{next_iteration:04d}_exploration"

    debate_path = Path(f"runtime/debates/{exp_name}.md")
    if debate_path.exists():
        raise SystemExit(f"Debate file already exists and must not be overwritten: {debate_path}")

    current.update({
        "exp_name": exp_name,
        "iteration": next_iteration,
        "objective_summary": objective.get("goal"),
        "candidate_directions": [],
        "deduplicated_directions": [],
        "selected_direction": None,
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
    })

    current_path.write_text(
        json.dumps(current, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8"
    )

    recent_records = val_loss.get("records", [])[:10]
    best_record = best.get("best")

    constraints_yaml = yaml.safe_dump(objective.get("constraints", {}), sort_keys=False)
    exploration_policy_yaml = yaml.safe_dump(objective.get("exploration_policy", {}), sort_keys=False)
    best_record_json = json.dumps(best_record, indent=2, ensure_ascii=False)
    recent_records_json = json.dumps(recent_records, indent=2, ensure_ascii=False)
    phase_b_schema_path = Path("workflow/oh-my-autoresearch/schemas/phase_b_agentteam_output.schema.json")
    phase_b_schema_json = json.dumps(
        json.loads(phase_b_schema_path.read_text(encoding="utf-8")),
        indent=2,
        ensure_ascii=False,
    )

    debate_text = f"""# AgentTeam Debate: {exp_name}

## Status

WAITING_FOR_AGENTTEAM

This file is generated by Phase B/B1. It may be authored ONLY by the project
agents in `.claude/agents/` (team-leader, math-theorist, numerical-debugger,
flow-arch-reviewer, orthogonal-direction-scout). The PreToolUse guard blocks the
main Claude turn from writing this file.

The main turn must invoke the project agents and let THEM fill the sections
below; it must not synthesize candidate directions, debate content, or a plan on
its own. If the agents are slow or their output is incomplete, WAIT and
re-invoke them — fabricating agent output to advance the loop is a protocol
violation and is forbidden.

---

## Experiment Metadata

- Experiment name: `{exp_name}`
- Iteration: {next_iteration}
- Created at: {now}
- Primary metric: `{objective.get("primary_metric", {}).get("name", "val_loss")}`
- Metric mode: `{objective.get("primary_metric", {}).get("mode", "minimize")}`

---

## Objective

{objective.get("goal")}

---

## Constraints

```yaml
{constraints_yaml}
```

---

## Exploration Policy

```yaml
{exploration_policy_yaml}
```

---

## Best Known Experiment

```json
{best_record_json}
```

---

## Recent Validation-Loss Records

```json
{recent_records_json}
```

---

## Learned Patterns

{learned}

---

## Rejected Ideas

{rejected}

---

# AgentTeam Task

Generate candidate architecture modifications for `project/nn-architecture`.

Use a FLAT (non-nested) AgentTeam. The orchestrator (main turn) invokes the
specialists DIRECTLY and IN PARALLEL, then invokes `team-leader` only to
reconcile. Do NOT invoke `team-leader` first and let it spawn the specialists —
that nesting is forbidden, and `team-leader` has no agent-spawning tool.

1. B1: orchestrator invokes `math-theorist`, `numerical-debugger`,
   `flow-arch-reviewer` in parallel; then `team-leader` reconciles.
2. B2: orchestrator invokes `orthogonal-direction-scout`; then `team-leader`
   reconciles.
3. B3: orchestrator invokes `math-theorist`, `numerical-debugger`,
   `flow-arch-reviewer` in parallel; then `team-leader` reconciles and confirms
   one plan.

The main Claude turn must not manually replace the project-agent discussion.
Invoke the named project agents, let them record their outputs in this file, and
only then apply the plan via `./scripts/apply_agentteam_plan.py --advance`.

The team must produce:

1. Three candidate directions per specialist role (`math-theorist`, `numerical-debugger`, `flow-arch-reviewer`).
2. A historical-overlap review against rejected ideas and previous experiments.
3. A debate over feasibility, expected validation-loss impact, implementation risk, and ablation value.
4. One selected direction.
5. A concrete modification plan.

Do not select a direction that substantially repeats rejected ideas unless there is a new mechanism or diagnostic reason.

---

# Required Output Format

Claude/AgentTeam must fill the following sections. Each JSON block must match
the same-named property in:

```text
workflow/oh-my-autoresearch/schemas/phase_b_agentteam_output.schema.json
```

The full machine-readable schema is embedded here to keep the debate prompt in
sync with the workflow-owned contract:

```json
{phase_b_schema_json}
```

## Candidate Directions

```json
[]
```

## Deduplicated Directions

```json
[]
```

## Debate Summary

Write the debate summary here.

## Agent Team Execution Log

Record which project agents were invoked for B1, B2, and B3. Include minority
objections and the team-leader reconciliation decision for each step. The
team-leader must wait for every required agent to finish, then explicitly
finalize and disband the team. Do not advance to Phase C until
`team_lifecycle.all_agents_completed`, `team_lifecycle.team_leader_finalized`,
and `team_lifecycle.team_disbanded` are all true for B1, B2, and B3.

## Selected Direction

```json
null
```

## Modification Plan

```json
null
```

---

# Required Runtime Updates After Filling This File

Runtime state is script-owned. Once the project agents have filled the four JSON
sections above (Candidate Directions, Deduplicated Directions, Selected
Direction, Modification Plan) AND the Agent Team Execution Log naming every
required agent, the plan is written into
`runtime/state/current_iteration.json` and the workflow advances to Phase C
ONLY through the sanctioned script:

```bash
cd /Users/liuxiaoyan/workspace/research-runtime
./scripts/apply_agentteam_plan.py --advance
./scripts/run_loop.sh
```

Do not hand-edit `runtime/state/current_iteration.json` or run
`./scripts/set_phase.sh` to jump ahead — the PreToolUse guard blocks the former
and `set_phase.sh` refuses non-adjacent phase jumps. `apply_agentteam_plan.py`
parses this file, validates it against the workflow schema, and refuses to apply
a fabricated or incomplete debate.
"""

    debate_path.write_text(debate_text, encoding="utf-8")

    timeline.setdefault("events", []).append({
        "time": now,
        "iteration": next_iteration,
        "exp_name": exp_name,
        "event_type": "phase_b_agentteam_prompt_created",
        "phase": "B",
        "summary": "Phase B created an AgentTeam debate prompt and is waiting for a real modification plan.",
        "best_val_loss": best_record.get("best_val_loss") if isinstance(best_record, dict) else None,
        "is_new_best": False
    })
    timeline_path.write_text(
        json.dumps(timeline, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8"
    )

    state.update({
        "workflow_status": "running",
        "phase": "B",
        "phase_step": "B2",
        "iteration": next_iteration,
        "current_exp_name": exp_name,
        "next_phase": "B",
        "blocked": False,
        "block_reason": None,
        "updated_at": now
    })
    state_path.write_text(
        json.dumps(state, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8"
    )

    print("== Phase B: Exploration Direction Generation ==")
    print(f"exp_name: {exp_name}")
    print(f"debate_path: {debate_path}")
    print("Phase B/B1 completed. Waiting for project-agent output at Phase B/B2.")
    raise SystemExit(0)

if phase_step == "B2":
    exp_name = current.get("exp_name")
    debate_path = Path(f"runtime/debates/{exp_name}.md") if exp_name else None

    print("== Phase B: Waiting for AgentTeam Output ==")
    print(f"exp_name: {exp_name}")
    print(f"debate_path: {debate_path}")

    if not exp_name or not debate_path or not debate_path.exists():
        reason = "Phase B/B2 requires existing debate file and current_iteration.exp_name"
        state.update({
            "workflow_status": "blocked",
            "phase": "BLOCKED",
            "phase_step": "BLOCKED",
            "blocked": True,
            "block_reason": reason,
            "updated_at": now,
        })
        state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        raise SystemExit(reason)

    if not current.get("modification_plan") or not current.get("selected_direction"):
        print("AgentTeam output is not ready.")
        print("The project agents must author the debate file (the main turn is")
        print("blocked from writing runtime/debates/**). Do NOT fabricate it.")
        print("Once the agents have filled it, apply the plan and advance with:")
        print("  ./scripts/apply_agentteam_plan.py --advance")
        print("  ./scripts/run_loop.sh")
        raise SystemExit(0)

    if not phase_b_team_complete(current):
        print("AgentTeam output is not ready.")
        print("B1, B2, and B3 must all have status=complete, exact completed_agents,")
        print("all_agents_completed=true, team_leader_finalized=true, and team_disbanded=true.")
        print("The team-leader must explicitly finalize and disband the team before Phase C.")
        raise SystemExit(0)

    state.update({
        "workflow_status": "running",
        "phase": "C",
        "phase_step": "C1",
        "next_phase": "C",
        "blocked": False,
        "block_reason": None,
        "updated_at": now
    })

    timeline.setdefault("events", []).append({
        "time": now,
        "iteration": state.get("iteration", current.get("iteration")),
        "exp_name": exp_name,
        "event_type": "phase_b_completed",
        "phase": "B",
        "summary": "AgentTeam output detected. Workflow advanced to Phase C.",
        "best_val_loss": best.get("best", {}).get("best_val_loss") if best.get("best") else None,
        "is_new_best": False
    })

    timeline_path.write_text(json.dumps(timeline, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print("Phase B/B2 completed. Advanced to Phase C/C1.")
    raise SystemExit(0)

reason = f"Unsupported Phase B step: {phase_step}"
state.update({
    "workflow_status": "blocked",
    "phase": "BLOCKED",
    "phase_step": "BLOCKED",
    "blocked": True,
    "block_reason": reason,
    "updated_at": now,
})
state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
raise SystemExit(reason)
PY
