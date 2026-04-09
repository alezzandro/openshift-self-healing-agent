#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../setup/ensure-authenticated.sh"

echo "=== Scenario 4: MachineConfigPool Degraded ==="
echo "This will apply a conflicting MachineConfig that prevents the MCO from"
echo "rendering the worker pool configuration. The worker MCP will report"
echo "Degraded immediately. No nodes reboot -- the render fails before any"
echo "drain/reboot is attempted."
echo ""

echo "Current worker MCP status:"
oc get mcp worker
echo ""

EXISTING=$(oc get mc self-healing-demo-conflict --no-headers 2>/dev/null || true)
if [ -n "${EXISTING}" ]; then
  echo "WARNING: Conflicting MachineConfig already exists."
  echo "Run cleanup.sh first, then trigger again."
  exit 1
fi

if [ -t 0 ]; then
  read -rp "Press ENTER to trigger the failure (apply conflicting MachineConfig)..."
else
  echo "Non-interactive mode: proceeding with conflicting MachineConfig..."
fi

echo ""
echo "Applying MachineConfig with an 'append' file entry (rejected by MCO render)..."
cat <<'EOF' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: self-healing-demo-conflict
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/self-healing-demo-conflict
          mode: 0644
          append:
            - source: data:text/plain;charset=utf-8,conflicting-append-entry
EOF

echo ""
echo "Waiting for worker MCP to become Degraded..."
for i in $(seq 1 30); do
  MCP_DEGRADED=$(oc get mcp worker \
    -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "")
  RENDER_DEGRADED=$(oc get mcp worker \
    -o jsonpath='{.status.conditions[?(@.type=="RenderDegraded")].status}' 2>/dev/null || echo "")
  if [ "${MCP_DEGRADED}" = "True" ] || [ "${RENDER_DEGRADED}" = "True" ]; then
    echo "  [OK] Worker MCP is Degraded"
    break
  fi
  echo "  Attempt ${i}/30 -- Degraded=${MCP_DEGRADED:-pending} RenderDegraded=${RENDER_DEGRADED:-pending}"
  sleep 10
done

echo ""
oc get mcp worker
echo ""
echo "The MCPDegraded alert should fire within ~1 minute."
echo "The EDA rulebook will trigger the self-healing workflow."
echo ""
echo "Watch:    oc get mcp worker -w"
echo "Console:  Observe > Alerting > MCPDegraded"
echo ""
echo "IMPORTANT: No nodes will reboot. The MCO render failed before scheduling"
echo "any drain/reboot. Existing node configuration is untouched."
echo ""
echo "To clean up:  ./demo/scenarios/04-mcp-degraded/cleanup.sh"
