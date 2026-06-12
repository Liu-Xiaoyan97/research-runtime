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
from pathlib import Path

experiments_dir = Path("runtime/experiments")
records = []

for p in sorted(experiments_dir.glob("*.json")):
    if p.name == "best.json":
        continue

    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as exc:
        records.append({
            "file": str(p),
            "exp_name": p.stem,
            "iteration": "?",
            "status": f"invalid_json: {exc}",
            "best_val_loss": None,
            "selected_direction": None,
        })
        continue

    metrics = data.get("metrics", {}) or {}

    records.append({
        "file": str(p),
        "exp_name": data.get("exp_name", p.stem),
        "iteration": data.get("iteration"),
        "status": data.get("status"),
        "best_val_loss": metrics.get("best_val_loss"),
        "selected_direction": data.get("selected_direction"),
    })

if not records:
    print("No experiment records found.")
    raise SystemExit(0)

print("== Experiments ==")
for r in records:
    print()
    print(f"exp_name:           {r['exp_name']}")
    print(f"iteration:          {r['iteration']}")
    print(f"status:             {r['status']}")
    print(f"best_val_loss:      {r['best_val_loss']}")
    print(f"selected_direction: {r['selected_direction']}")
    print(f"file:               {r['file']}")
PY