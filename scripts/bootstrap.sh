#!/usr/bin/env bash
set -euo pipefail

# Resolve repository root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKFLOW_DIR="$ROOT_DIR/workflow/oh-my-autoresearch"
TEMPLATE_RUNTIME_DIR="$WORKFLOW_DIR/templates/nn_architecture/runtime"
PYTHON_BIN="$ROOT_DIR/.venv/bin/python"

cd "$ROOT_DIR"

if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi

if [ -z "${PYTHON_BIN:-}" ]; then
  echo "Python not found. Expected .venv/bin/python or python3."
  exit 1
fi

echo "ROOT_DIR=$ROOT_DIR"
echo "WORKFLOW_DIR=$WORKFLOW_DIR"
echo "Using Python: $PYTHON_BIN"

if [ ! -d "$WORKFLOW_DIR" ]; then
  echo "Missing workflow submodule: $WORKFLOW_DIR"
  echo "Run: git submodule update --init --recursive"
  exit 1
fi

if [ ! -d "$TEMPLATE_RUNTIME_DIR" ]; then
  echo "Missing runtime template directory: $TEMPLATE_RUNTIME_DIR"
  exit 1
fi

mkdir -p runtime
mkdir -p runtime/objective
mkdir -p runtime/state
mkdir -p runtime/history
mkdir -p runtime/knowledge
mkdir -p runtime/debates
mkdir -p runtime/experiments
mkdir -p runtime/training
mkdir -p .claude/agents
mkdir -p .claude/commands
mkdir -p .claude/hooks

# Copy runtime files only if missing.
copy_if_missing() {
  local src="$1"
  local dst="$2"

  if [ ! -f "$dst" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "Created $dst"
  else
    echo "Exists, skipped $dst"
  fi
}

copy_if_missing "$TEMPLATE_RUNTIME_DIR/objective/objective.yaml" \
  "$ROOT_DIR/runtime/objective/objective.yaml"

copy_if_missing "$TEMPLATE_RUNTIME_DIR/state/state.json" \
  "$ROOT_DIR/runtime/state/state.json"

copy_if_missing "$TEMPLATE_RUNTIME_DIR/state/current_iteration.json" \
  "$ROOT_DIR/runtime/state/current_iteration.json"

copy_if_missing "$TEMPLATE_RUNTIME_DIR/state/val_loss.json" \
  "$ROOT_DIR/runtime/state/val_loss.json"

copy_if_missing "$TEMPLATE_RUNTIME_DIR/history/timeline.json" \
  "$ROOT_DIR/runtime/history/timeline.json"

copy_if_missing "$TEMPLATE_RUNTIME_DIR/knowledge/learned_patterns.md" \
  "$ROOT_DIR/runtime/knowledge/learned_patterns.md"

copy_if_missing "$TEMPLATE_RUNTIME_DIR/knowledge/rejected_ideas.md" \
  "$ROOT_DIR/runtime/knowledge/rejected_ideas.md"

copy_if_missing "$TEMPLATE_RUNTIME_DIR/experiments/best.json" \
  "$ROOT_DIR/runtime/experiments/best.json"

copy_if_missing "$TEMPLATE_RUNTIME_DIR/training/entrypoint.yaml" \
  "$ROOT_DIR/runtime/training/entrypoint.yaml"

copy_if_missing "$WORKFLOW_DIR/CLAUDE.template.md" \
  "$ROOT_DIR/CLAUDE.md"

copy_if_missing "$WORKFLOW_DIR/.claude.template/settings.json" \
  "$ROOT_DIR/.claude/settings.json"

for agent_file in "$WORKFLOW_DIR"/agents/*.md; do
  copy_if_missing "$agent_file" \
    "$ROOT_DIR/.claude/agents/$(basename "$agent_file")"
done

for command_file in "$WORKFLOW_DIR"/.claude.template/commands/*.md; do
  copy_if_missing "$command_file" \
    "$ROOT_DIR/.claude/commands/$(basename "$command_file")"
done

for hook_file in "$WORKFLOW_DIR"/.claude.template/hooks/*.py; do
  copy_if_missing "$hook_file" \
    "$ROOT_DIR/.claude/hooks/$(basename "$hook_file")"
done

# CLAUDE.md can be overwritten from template during bootstrap.
cp "$WORKFLOW_DIR/CLAUDE.template.md" "$ROOT_DIR/runtime/CLAUDE.md"
echo "Synced runtime/CLAUDE.md"

touch "$ROOT_DIR/runtime/debates/.gitkeep"

echo "Runtime bootstrap completed."
