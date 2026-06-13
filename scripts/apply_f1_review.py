#!/usr/bin/env python3
"""Apply a Phase F1 AgentTeam evidence review into runtime state.

This is the sanctioned bridge for Phase F1, mirroring apply_agentteam_plan.py
for Phase B. It exists so that the F1 verdict reaches
runtime/state/current_iteration.json **only** through a script (a subprocess,
which bypasses the tool-write guard), never through a hand-edit by the main
Claude turn.

It parses the agent-authored review file:

    runtime/debates/<exp_name>_f1_review.md

The review file must contain a machine-readable verdict block:

    ## F1 Verdict
    ```json
    {
      "verdict": "learned | rejected | inconclusive",
      "summary": "<evidence-grounded reconciliation, written by team-leader>",
      "missing_evidence": ["..."],
      "agent_votes": [
        {"agent": "math-theorist", "verdict": "...", "rationale": "..."},
        {"agent": "numerical-debugger", "verdict": "...", "rationale": "..."},
        {"agent": "flow-arch-reviewer", "verdict": "...", "rationale": "..."}
      ]
    }
    ```

and an "## Agent Team Execution Log" section that attributes contributions to
each required F1 agent, so we can confirm the team actually ran rather than the
main turn fabricating a verdict.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.apply_agentteam_plan import extract_json_blocks, extract_section

F1_AGENTS = ["team-leader", "math-theorist", "numerical-debugger", "flow-arch-reviewer"]
VALID_VERDICTS = {"learned", "rejected", "inconclusive"}
PLACEHOLDER_SUMMARIES = {
    "...",
    "summary",
    "write the summary here",
    "evidence-grounded reconciliation",
}


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def closed_team_lifecycle(timestamp: str) -> dict[str, Any]:
    return {
        "required_agents": F1_AGENTS,
        "completed_agents": F1_AGENTS,
        "all_agents_completed": True,
        "team_leader_finalized": True,
        "team_disbanded": True,
        "disbanded_at": timestamp,
        "notes": [
            "F1 project-agent team completed, team-leader finalized, and team was disbanded.",
        ],
    }


def validate_verdict_block(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("F1 Verdict must be a JSON object")

    verdict = value.get("verdict")
    if verdict not in VALID_VERDICTS:
        raise ValueError(
            f"F1 Verdict.verdict must be one of {sorted(VALID_VERDICTS)}, got {verdict!r}"
        )

    summary = value.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        raise ValueError("F1 Verdict.summary must be a non-empty string")
    if summary.strip().lower() in PLACEHOLDER_SUMMARIES:
        raise ValueError(f"F1 Verdict.summary appears to be a placeholder: {summary!r}")

    missing_evidence = value.get("missing_evidence", [])
    if not isinstance(missing_evidence, list):
        raise ValueError("F1 Verdict.missing_evidence must be a list")

    agent_votes = value.get("agent_votes", [])
    if not isinstance(agent_votes, list):
        raise ValueError("F1 Verdict.agent_votes must be a list")

    return value


def require_execution_log(text: str) -> None:
    """Confirm the review attributes work to every required F1 agent.

    This is a structural anti-fabrication gate: the agent-authored review must
    name each required agent in its execution log. It does not prove the agents
    ran, but combined with the debate-file write guard (only project agents may
    author runtime/debates/**) it makes fabrication materially harder.
    """
    try:
        log_section = extract_section(text, "Agent Team Execution Log")
    except ValueError as exc:
        raise ValueError(
            "F1 review is missing the '## Agent Team Execution Log' section. "
            "The team-leader must record each agent's contribution before a "
            "verdict can be applied."
        ) from exc

    lowered = log_section.lower()
    missing = [agent for agent in F1_AGENTS if agent.lower() not in lowered]
    if missing:
        raise ValueError(
            "F1 Agent Team Execution Log does not reference required agents: "
            + ", ".join(missing)
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="Path to autoresearch-runtime root")
    parser.add_argument(
        "--exp-name",
        default=None,
        help="Experiment name. Defaults to current_iteration.exp_name",
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
        raise SystemExit(
            "Missing exp_name. Provide --exp-name or set current_iteration.exp_name."
        )

    review_path = root / f"runtime/debates/{exp_name}_f1_review.md"
    if not review_path.exists():
        raise SystemExit(
            f"F1 review file not found: {review_path}\n"
            "Run Phase F first so it generates the review prompt, then let the F1 "
            "project agents fill it. Do NOT fabricate the review yourself."
        )

    text = review_path.read_text(encoding="utf-8")

    require_execution_log(text)

    verdict_block = None
    errors: list[str] = []
    for idx, block in enumerate(
        extract_json_blocks(extract_section(text, "F1 Verdict"), "F1 Verdict")
    ):
        try:
            verdict_block = validate_verdict_block(block)
            break
        except ValueError as exc:
            errors.append(f"block {idx}: {exc}")
    if verdict_block is None:
        raise SystemExit(
            "No valid F1 Verdict JSON block found. Errors: " + "; ".join(errors)
        )

    now = datetime.now(timezone.utc).isoformat()
    verdict = verdict_block["verdict"]
    summary = verdict_block["summary"].strip()
    missing_evidence = verdict_block.get("missing_evidence", [])
    agent_votes = verdict_block.get("agent_votes", [])

    agentteam = current.setdefault("agentteam", {})
    f1 = agentteam.setdefault("f1_evidence_review", {})
    f1.update(
        {
            "status": "complete",
            "agents": F1_AGENTS,
            "team_lifecycle": closed_team_lifecycle(now),
            "summary": summary,
            "verdict": verdict,
            "missing_evidence": missing_evidence,
        }
    )

    current["root_cause_analysis"] = {
        "status": "complete",
        "agent_votes": agent_votes,
        "verdict": verdict,
        "summary": summary,
    }
    current["updated_at"] = now

    timeline.setdefault("events", []).append(
        {
            "time": now,
            "iteration": current.get("iteration", state.get("iteration")),
            "exp_name": exp_name,
            "event_type": "f1_review_applied",
            "phase": "F",
            "summary": f"F1 AgentTeam evidence review applied. Verdict: {verdict}",
            "best_val_loss": None,
            "is_new_best": False,
        }
    )

    write_json(current_path, current)
    write_json(timeline_path, timeline)

    print(f"Applied F1 evidence review from: {review_path}")
    print(f"Verdict: {verdict}")
    print("Re-run ./scripts/run_loop.sh to let Phase F write the checkpoint.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
