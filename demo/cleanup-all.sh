#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../setup/ensure-authenticated.sh"

echo "=== Running all cleanup scripts ==="
echo ""

for track in infrastructure gitops; do
  track_dir="${SCRIPT_DIR}/${track}/scenarios"
  [ -d "${track_dir}" ] || continue
  for scenario_dir in "${track_dir}"/*/; do
    [ -d "${scenario_dir}" ] || continue
    scenario_name=$(basename "${scenario_dir}")
    cleanup_script="${scenario_dir}cleanup.sh"
    if [ -f "${cleanup_script}" ]; then
      echo "--- Running cleanup for: ${track}/${scenario_name} ---"
      bash "${cleanup_script}" || echo "WARNING: Cleanup for ${track}/${scenario_name} had issues"
      echo ""
    fi
  done
done

echo "=== All cleanups completed ==="
