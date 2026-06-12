#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== Git status =="
git status --short

echo
echo "== Submodules =="
git submodule status || true

echo
echo "== Workflow state =="
if [ -f runtime/state/state.json ]; then
  cat runtime/state/state.json
else
  echo "runtime/state/state.json not found"
fi

echo
echo "== Current iteration =="
if [ -f runtime/state/current_iteration.json ]; then
  cat runtime/state/current_iteration.json
else
  echo "runtime/state/current_iteration.json not found"
fi

echo
echo "== Best experiment =="
if [ -f runtime/experiments/best.json ]; then
  cat runtime/experiments/best.json
else
  echo "runtime/experiments/best.json not found"
fi