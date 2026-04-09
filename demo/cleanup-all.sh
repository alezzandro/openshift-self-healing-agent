#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../setup/ensure-authenticated.sh"

echo "=== Running all cleanup scripts ==="
echo ""

for scenario_dir in "${SCRIPT_DIR}"/scenarios/*/; do
  scenario_name=$(basename "${scenario_dir}")
  cleanup_script="${scenario_dir}cleanup.sh"
  if [ -f "${cleanup_script}" ]; then
    echo "--- Running cleanup for: ${scenario_name} ---"
    bash "${cleanup_script}" || echo "WARNING: Cleanup for ${scenario_name} had issues"
    echo ""
  fi
done

echo "=== All cleanups completed ==="
