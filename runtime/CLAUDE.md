# AutoResearch Loop Protocol

You are operating inside a runtime repository generated from `oh-my-autoresearch`.

This is a loop-executed autonomous research project. Your default action is to
advance the loop by running:

```bash
./scripts/run_loop.sh
```

After any phase finishes, immediately inspect `runtime/state/state.json` and
continue with `./scripts/run_loop.sh` until the workflow reaches `BLOCKED` or
`DONE`. Do not stop after a single phase just because the phase completed.
Human intervention is required only when the workflow state is `BLOCKED`, when
the state is `DONE`, or when a command fails in a way the workflow cannot
repair.

You MUST treat `runtime/` as the source of truth.

Do not rely on chat history as the primary workflow state.

## Environment

This repository uses `uv` for Python environment management.

- Prefer `uv run ...` for project commands when a `pyproject.toml` is present.
- Do not use `pip install` directly unless the user explicitly asks.
- Do not create ad hoc virtual environments; use the checked-in uv project
  configuration.
- The target research project is in `project/nn-architecture` and has its own
  `pyproject.toml` / `uv.lock`.

## Schema And Script Ownership

Do not hand-edit runtime JSON into an invented shape. Runtime JSON must match
the workflow schemas in:

```text
workflow/oh-my-autoresearch/schemas/
runtime/schemas/
```

Use the repository scripts to create and advance runtime state:

- `./scripts/phases/phase_b_exploration.sh`
- `./scripts/apply_agentteam_plan.py`
- `./scripts/phases/phase_c_local_validation.sh`
- `./scripts/phases/phase_d_remote_launch.sh`
- `./scripts/phases/phase_e_monitoring.sh`
- `./scripts/phases/phase_f_checkpoint.sh`
- `./scripts/validate_runtime.sh`
- `./scripts/validate_schema.sh`

If you write or update `runtime/state/*.json`, `runtime/history/timeline.json`,
or `runtime/experiments/*.json`, run validation before stopping:

```bash
./scripts/validate_runtime.sh
./scripts/validate_schema.sh
```

## Required Runtime Reads

At the beginning of every loop, read:

- runtime/objective/objective.yaml
- runtime/state/state.json
- runtime/state/current_iteration.json
- runtime/state/val_loss.json
- runtime/knowledge/learned_patterns.md
- runtime/knowledge/rejected_ideas.md
- runtime/history/timeline.json
- runtime/experiments/best.json

## Phase Routing

### Current phase

The current phase is defined by:

```text
runtime/state/state.json
```
If the current phase is not A, do not restart from Phase A. Resume from the recorded phase.

### Allowed phases

* A: History Maintenance
* B: Exploration Direction Generation
* C: Implementation and Local Validation
* D: Remote Training Launch
* E: Monitoring and Result Retrieval
* F: Checkpoint Write
* BLOCKED
* DONE

## Repository Responsibility

* Modify workflow templates only in oh-my-autoresearch.
* Modify model code only in nn-architecture.
* Modify runtime state only in research-runtime/runtime.

## Phases

### Phase A

Read state, current iteration, validation loss index, learned patterns, rejected ideas, timeline, and best experiment.

If state.phase is not A, jump to the recorded phase.

### Phase B

Use the project agents installed in `.claude/agents/` to generate and review
candidate research directions from:

* objective.yaml
* learned_patterns.md
* rejected_ideas.md
* timeline.json
* val_loss.json
* best.json

Phase B has three project-agent steps:

* B1: `team-leader`, `math-theorist`, `numerical-debugger`, and `flow-arch-reviewer` generate and stress-test candidates.
* B2: `team-leader` and `orthogonal-direction-scout` review candidates for historical overlap and orthogonality.
* B3: `team-leader`, `math-theorist`, `numerical-debugger`, and `flow-arch-reviewer` debate the B2 survivors and select one implementation plan.

Deduplicate candidates against historical attempts before writing the final plan.

Write debate output to:
runtime/debates/<exp_name>.md

Write selected direction, deduplicated candidates, AgentTeam summaries, and modification plan to:
runtime/state/current_iteration.json

### Phase C

Use the coding executor to modify the nn-architecture repository according to the selected plan.

Run local smoke tests.

If tests fail, set:
{
  "workflow_status": "blocked",
  "phase": "BLOCKED",
  "blocked": true,
  "block_reason": "Local validation failed"
}

### Phase D
Launch training. If `workflow.config.json` disables remote training, run the
local training entrypoint from `runtime/training/entrypoint.yaml`; otherwise
upload modified code to the remote training server and start training.

- Record training status in `runtime/state/current_iteration.json`.

### Phase E

Monitor remote training using cron or an equivalent scheduled mechanism.

Do not use long-running sleep + ssh polling loops.

- Append or update validation loss records in `runtime/state/val_loss.json`.
- When training finishes, write full experiment results to `runtime/experiments/<exp_name>.json`.
- Cancel expired cron monitors.

### Phase F

Compare current experiment results against `runtime/experiments/best.json`.

- If improved, update `runtime/experiments/best.json`.
- Run F1 AgentTeam root cause analysis with `team-leader`, `math-theorist`, `numerical-debugger`, and `flow-arch-reviewer`.
- If the method is judged effective, append the method and analysis to `runtime/knowledge/learned_patterns.md`.
- If the method is judged ineffective or harmful, append the method and analysis to `runtime/knowledge/rejected_ideas.md`.
- If the evidence is insufficient, mark the verdict `inconclusive` and record the missing evidence without forcing a learned/rejected update.
- Append the experiment event to `runtime/history/timeline.json`.
- Update `runtime/state/state.json` to return to Phase A.
