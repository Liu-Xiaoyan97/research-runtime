#!/usr/bin/env bash
set -euo pipefail

FORCE=0
REASON=""
# Parse leading options (--force / --reason) in any order.
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --force) FORCE=1; shift ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
if [ "${AUTORESEARCH_ALLOW_PHASE_OVERRIDE:-0}" = "1" ]; then
  FORCE=1
fi

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 [--force] [--reason <text>] <PHASE> [PHASE_STEP]"
  echo "Example: $0 B B1"
  echo "Example: $0 --reason 'paused by user' BLOCKED"
  echo
  echo "Without --force, only adjacent forward transitions are allowed:"
  echo "  A -> B -> C -> D -> E -> F -> A   (and same-phase step changes)"
  echo "  any phase -> BLOCKED / DONE        (always allowed)"
  echo "  BLOCKED -> any                     (human recovery)"
  echo "Use --force (or AUTORESEARCH_ALLOW_PHASE_OVERRIDE=1) to override; this is"
  echo "a human escape hatch, not for the automated loop."
  echo "--reason sets block_reason when PHASE is BLOCKED (a non-empty reason is"
  echo "required by the schema)."
  exit 1
fi

PHASE="$1"
# BLOCKED/DONE have no numbered sub-steps; default their step to the phase name.
if [ "$PHASE" = "BLOCKED" ] || [ "$PHASE" = "DONE" ]; then
  PHASE_STEP="${2:-$PHASE}"
else
  PHASE_STEP="${2:-${PHASE}1}"
fi

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

"$PYTHON_BIN" - "$PHASE" "$PHASE_STEP" "$FORCE" "$REASON" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

phase = sys.argv[1]
phase_step = sys.argv[2]
force = sys.argv[3] == "1"
reason = sys.argv[4] if len(sys.argv) > 4 else ""

allowed = {"A", "B", "C", "D", "E", "F", "BLOCKED", "DONE"}
if phase not in allowed:
    raise SystemExit(f"Invalid phase: {phase}. Allowed: {sorted(allowed)}")

path = Path("runtime/state/state.json")
data = json.loads(path.read_text(encoding="utf-8"))
current_phase = data.get("phase")

# Canonical forward cycle for the autonomous loop.
next_phase = {"A": "B", "B": "C", "C": "D", "D": "E", "E": "F", "F": "A"}

def transition_allowed(src, dst):
    if force:
        return True
    if dst in ("BLOCKED", "DONE"):
        return True
    if src in (None, "BLOCKED"):
        # Fresh state or human recovery from a blocked state.
        return True
    if dst == src:
        # Same-phase step change (e.g. F/F1 -> F/F2).
        return True
    if next_phase.get(src) == dst:
        return True
    return False

if not transition_allowed(current_phase, phase):
    raise SystemExit(
        f"Refusing phase transition {current_phase} -> {phase}: not an adjacent "
        f"forward move. Allowed next phase from {current_phase} is "
        f"{next_phase.get(current_phase)!r} (or BLOCKED/DONE). "
        "Skipping or rewinding phases bypasses the workflow. "
        "Re-run ./scripts/run_loop.sh to advance normally, or pass --force only "
        "as a deliberate human override."
    )

data["phase"] = phase
data["phase_step"] = phase_step
data["next_phase"] = phase
data["updated_at"] = datetime.now(timezone.utc).isoformat()

if phase == "BLOCKED":
    data["workflow_status"] = "blocked"
    data["blocked"] = True
    data["block_reason"] = reason.strip() or "Workflow set to BLOCKED via set_phase.sh (no reason provided)."
elif phase == "DONE":
    data["workflow_status"] = "done"
    data["blocked"] = False
    data["block_reason"] = None
else:
    data["workflow_status"] = "running"
    data["blocked"] = False
    data["block_reason"] = None

path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

print(f"Updated phase -> {phase}/{phase_step}" + (" (forced)" if force else ""))
PY
