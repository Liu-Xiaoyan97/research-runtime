#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_DIR="$ROOT_DIR/workflow/oh-my-autoresearch"
TEMPLATE_RUNTIME_DIR="$WORKFLOW_DIR/templates/nn_architecture/runtime"
PYTHON_BIN="$ROOT_DIR/.venv/bin/python"

YES=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/reset_runtime.sh --yes
  ./scripts/reset_runtime.sh --dry-run

Reset runtime state for a fresh local/Claude Code CLI test run.

This script:
  - deletes runtime/experiments/exp_*.json
  - deletes runtime/experiments/exp_*.metrics.json
  - deletes runtime/debates/exp_*.md
  - resets runtime/history/timeline.json
  - resets runtime/knowledge/learned_patterns.md
  - resets runtime/knowledge/rejected_ideas.md
  - resets runtime/state/current_iteration.json
  - resets runtime/state/state.json
  - resets runtime/state/val_loss.json
  - resets runtime/experiments/best.json

It does not reset runtime/objective/objective.yaml or workflow.config.json.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --yes|-y)
      YES=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  usage >&2
  echo >&2
  echo "Refusing to reset runtime without --yes or --dry-run." >&2
  exit 2
fi

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi

if [ -z "${PYTHON_BIN:-}" ]; then
  echo "Python not found. Expected .venv/bin/python or python3." >&2
  exit 1
fi

cd "$ROOT_DIR"

if [ ! -d "$WORKFLOW_DIR" ]; then
  echo "Missing workflow submodule: $WORKFLOW_DIR" >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

if [ ! -d "$TEMPLATE_RUNTIME_DIR" ]; then
  echo "Missing runtime template directory: $TEMPLATE_RUNTIME_DIR" >&2
  exit 1
fi

"$PYTHON_BIN" - "$DRY_RUN" <<'PY'
from __future__ import annotations

import shutil
import sys
from pathlib import Path


dry_run = sys.argv[1] == "1"

root = Path(".").resolve()
template_root = root / "workflow/oh-my-autoresearch/templates/nn_architecture/runtime"

copy_pairs = [
    (
        template_root / "history/timeline.json",
        root / "runtime/history/timeline.json",
    ),
    (
        template_root / "knowledge/learned_patterns.md",
        root / "runtime/knowledge/learned_patterns.md",
    ),
    (
        template_root / "knowledge/rejected_ideas.md",
        root / "runtime/knowledge/rejected_ideas.md",
    ),
    (
        template_root / "state/current_iteration.json",
        root / "runtime/state/current_iteration.json",
    ),
    (
        template_root / "state/state.json",
        root / "runtime/state/state.json",
    ),
    (
        template_root / "state/val_loss.json",
        root / "runtime/state/val_loss.json",
    ),
    (
        template_root / "experiments/best.json",
        root / "runtime/experiments/best.json",
    ),
]

delete_specs = [
    (
        root / "runtime/experiments",
        "exp_*.json",
        lambda path: not path.name.endswith(".metrics.json"),
    ),
    (
        root / "runtime/experiments",
        "exp_*.metrics.json",
        lambda path: True,
    ),
    (
        root / "runtime/debates",
        "exp_*.md",
        lambda path: True,
    ),
]


def display(path: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


missing_templates = [src for src, _ in copy_pairs if not src.is_file()]
if missing_templates:
    print("Missing reset templates:", file=sys.stderr)
    for path in missing_templates:
        print(f"- {display(path)}", file=sys.stderr)
    raise SystemExit(1)

print("== Runtime Reset Plan ==")
for directory, pattern, predicate in delete_specs:
    matches = sorted(path for path in directory.glob(pattern) if predicate(path))
    if matches:
        for path in matches:
            print(f"delete {display(path)}")
    else:
        print(f"delete {display(directory / pattern)} (no matches)")

for src, dst in copy_pairs:
    print(f"reset  {display(dst)} <- {display(src)}")

print()

if dry_run:
    print("Dry run only. No files were changed.")
    raise SystemExit(0)

for directory, pattern, predicate in delete_specs:
    for path in sorted(path for path in directory.glob(pattern) if predicate(path)):
        if path.is_file():
            path.unlink()

for src, dst in copy_pairs:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)

(root / "runtime/debates").mkdir(parents=True, exist_ok=True)
(root / "runtime/debates/.gitkeep").touch()
(root / "runtime/experiments").mkdir(parents=True, exist_ok=True)

print("Runtime reset completed.")
PY

echo
if [ "$DRY_RUN" -eq 0 ]; then
  echo "Validating reset runtime..."
  "$ROOT_DIR/scripts/validate_runtime.sh"
fi
