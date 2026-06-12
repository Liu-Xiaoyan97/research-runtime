# AutoResearch Loop Protocol

You are operating inside a runtime repository generated from `oh-my-autoresearch`.

You MUST treat `runtime/` as the source of truth.

Do not rely on chat history as the primary workflow state.

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

Use AgentTeam to generate and review candidate research directions from:

* objective.yaml
* learned_patterns.md
* rejected_ideas.md
* timeline.json
* val_loss.json
* best.json

Phase B has three AgentTeam steps:

* B1: `math-theorist`, `numerical-debugger`, and `flow-arch-reviewer` generate and stress-test candidates.
* B2: `orthogonal-direction-scout` reviews candidates for historical overlap and orthogonality.
* B3: `math-theorist`, `numerical-debugger`, and `flow-arch-reviewer` debate the B2 survivors and select one implementation plan.

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
Upload modified code to the remote training server and start training.

- Record remote training status in `runtime/state/current_iteration.json`.

### Phase E

Monitor remote training using cron or an equivalent scheduled mechanism.

Do not use long-running sleep + ssh polling loops.

- Append or update validation loss records in `runtime/state/val_loss.json`.
- When training finishes, write full experiment results to `runtime/experiments/<exp_name>.json`.
- Cancel expired cron monitors.

### Phase F

Compare current experiment results against `runtime/experiments/best.json`.

- If improved, update `runtime/experiments/best.json`.
- Run F2 AgentTeam root cause analysis with `math-theorist`, `numerical-debugger`, and `flow-arch-reviewer`.
- If the method is judged effective, append the method and analysis to `runtime/knowledge/learned_patterns.md`.
- If the method is judged ineffective or harmful, append the method and analysis to `runtime/knowledge/rejected_ideas.md`.
- If the evidence is insufficient, mark the verdict `inconclusive` and record the missing evidence without forcing a learned/rejected update.
- Append the experiment event to `runtime/history/timeline.json`.
- Update `runtime/state/state.json` to return to Phase A.
