#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../setup/ensure-authenticated.sh"

echo "=== Cleanup: MachineConfigPool Degraded ==="

EXISTING=$(oc get mc self-healing-demo-conflict --no-headers 2>/dev/null || true)
if [ -z "${EXISTING}" ]; then
  echo "Conflicting MachineConfig not found. Nothing to clean up."
  oc get mcp worker
  exit 0
fi

echo "Deleting conflicting MachineConfig: self-healing-demo-conflict..."
oc delete mc self-healing-demo-conflict

echo ""
echo "Waiting for worker MCP to recover..."
for i in $(seq 1 60); do
  DEGRADED=$(oc get mcp worker \
    -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "")
  UPDATED=$(oc get mcp worker \
    -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "")
  UPDATING=$(oc get mcp worker \
    -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "")
  if [ "${DEGRADED}" = "False" ] && [ "${UPDATED}" = "True" ]; then
    echo "  [OK] Worker MCP is healthy (Updated=True, Degraded=False)."
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    echo "  Attempt ${i}/60 -- Degraded=${DEGRADED:-?} Updated=${UPDATED:-?} Updating=${UPDATING:-?}"
  fi
  sleep 5
done

echo ""
echo "Cleanup complete."
oc get mcp worker
