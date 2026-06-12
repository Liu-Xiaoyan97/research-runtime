#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <PHASE> [PHASE_STEP]"
  echo "Example: $0 B B1"
  exit 1
fi

PHASE="$1"
PHASE_STEP="${2:-${PHASE}1}"

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

"$PYTHON_BIN" - "$PHASE" "$PHASE_STEP" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

phase = sys.argv[1]
phase_step = sys.argv[2]

allowed = {"A", "B", "C", "D", "E", "F", "BLOCKED", "DONE"}
if phase not in allowed:
    raise SystemExit(f"Invalid phase: {phase}. Allowed: {sorted(allowed)}")

path = Path("runtime/state/state.json")
data = json.loads(path.read_text(encoding="utf-8"))

data["phase"] = phase
data["phase_step"] = phase_step
data["next_phase"] = phase
data["updated_at"] = datetime.now(timezone.utc).isoformat()

if phase == "BLOCKED":
    data["workflow_status"] = "blocked"
    data["blocked"] = True
elif phase == "DONE":
    data["workflow_status"] = "done"
    data["blocked"] = False
    data["block_reason"] = None
else:
    data["workflow_status"] = "running"
    data["blocked"] = False
    data["block_reason"] = None

path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

print(f"Updated phase -> {phase}/{phase_step}")
PY