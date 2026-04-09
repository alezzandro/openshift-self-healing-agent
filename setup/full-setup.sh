#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "============================================"
echo "  OpenShift Self-Healing Agent - Full Setup"
echo "============================================"
echo ""

run_step() {
  local script="$1"
  local name
  name=$(basename "${script}" .sh)
  echo ""
  echo "============================================"
  echo "  Running: ${name}"
  echo "============================================"
  bash "${script}"
  echo ""
  echo "  ${name} completed."
  echo ""
}

run_step "${SCRIPT_DIR}/00-prereqs.sh"
run_step "${SCRIPT_DIR}/01-install-operators.sh"

echo "Waiting 60 seconds for operators to stabilize..."
sleep 60

run_step "${SCRIPT_DIR}/02-configure-gpu.sh"
run_step "${SCRIPT_DIR}/03-configure-rhoai.sh"
run_step "${SCRIPT_DIR}/04-deploy-gitea.sh"
run_step "${SCRIPT_DIR}/05-configure-servicenow.sh"
run_step "${SCRIPT_DIR}/06-deploy-mcp-servers.sh"
run_step "${SCRIPT_DIR}/07-configure-aap.sh"
run_step "${SCRIPT_DIR}/08-configure-monitoring.sh"

echo ""
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Open the AAP Controller UI"
echo "  2. Open your ServiceNow Developer Instance"
echo "  3. Trigger a demo scenario:"
echo "     ./demo/scenarios/01-worker-node-failure/trigger.sh"
echo ""
echo "See docs/demo-walkthrough.md for the full demo guide."
