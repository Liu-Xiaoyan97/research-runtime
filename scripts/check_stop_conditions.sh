#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    raise SystemExit(
        "Missing dependency: pyyaml. Install it with: .venv/bin/pip install pyyaml"
    )

objective = yaml.safe_load(Path("runtime/objective/objective.yaml").read_text(encoding="utf-8"))
state = json.loads(Path("runtime/state/state.json").read_text(encoding="utf-8"))
val_loss = json.loads(Path("runtime/state/val_loss.json").read_text(encoding="utf-8"))

stop = objective.get("stop_conditions", {})
success = objective.get("success_criteria", {})
target = success.get("target_metric", {})

iteration = state.get("iteration", 0)
records = val_loss.get("records", [])

should_stop = False
reasons = []

max_iterations = stop.get("max_iterations")
if isinstance(max_iterations, int) and iteration >= max_iterations:
    should_stop = True
    reasons.append(f"max_iterations reached: {iteration} >= {max_iterations}")

if stop.get("reach_target_metric") and target.get("value") is not None:
    target_value = target.get("value")
    op = target.get("operator", "<=")

    successful = [
        r for r in records
        if r.get("status") == "success" and r.get("best_val_loss") is not None
    ]

    if successful:
        best = min(r["best_val_loss"] for r in successful)
        if op == "<=" and best <= target_value:
            should_stop = True
            reasons.append(f"target reached: best_val_loss {best} <= {target_value}")
        elif op == "<" and best < target_value:
            should_stop = True
            reasons.append(f"target reached: best_val_loss {best} < {target_value}")

patience = stop.get("no_improvement_patience")
if isinstance(patience, int) and patience > 0:
    successful = [
        r for r in records
        if r.get("status") == "success" and r.get("best_val_loss") is not None
    ]

    if len(successful) > patience:
        best_so_far = float("inf")
        last_improvement_index = -1

        for idx, r in enumerate(successful):
            loss = r["best_val_loss"]
            if loss < best_so_far:
                best_so_far = loss
                last_improvement_index = idx

        since_improvement = len(successful) - 1 - last_improvement_index
        if since_improvement >= patience:
            should_stop = True
            reasons.append(
                f"no improvement patience reached: {since_improvement} >= {patience}"
            )

print("== Stop Condition Check ==")
print(f"should_stop: {should_stop}")
if reasons:
    print("reasons:")
    for reason in reasons:
        print(f"- {reason}")
else:
    print("reasons: none")

if should_stop:
    state["workflow_status"] = "done"
    state["phase"] = "DONE"
    state["phase_step"] = "DONE"
    state["next_phase"] = "DONE"
    Path("runtime/state/state.json").write_text(
        json.dumps(state, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    sys.exit(10)
PY