#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "AutoResearch loop entrypoint"
echo
echo "Claude Code should be started from this repository root."
echo
echo "Required runtime files:"
echo "- runtime/objective/objective.yaml"
echo "- runtime/state/state.json"
echo "- runtime/state/current_iteration.json"
echo "- runtime/state/val_loss.json"
echo "- runtime/history/timeline.json"
echo "- runtime/knowledge/learned_patterns.md"
echo "- runtime/knowledge/rejected_ideas.md"
echo "- runtime/experiments/best.json"
echo
echo "Current phase:"
if [ -f runtime/state/state.json ]; then
  python - <<'PY'
import json
from pathlib import Path

p = Path("runtime/state/state.json")
data = json.loads(p.read_text())
print(data.get("phase"), data.get("phase_step"))
PY
else
  echo "runtime/state/state.json not found. Run ./scripts/bootstrap.sh first."
  exit 1
fi