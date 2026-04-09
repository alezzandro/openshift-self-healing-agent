#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../setup/ensure-authenticated.sh"

echo "=== Scenario 1: Worker Node Failure ==="
echo "This will cordon, drain, and stop the kubelet on a worker node,"
echo "causing the KubeNodeNotReady alert to fire."
echo ""

# Select a non-GPU, non-protected worker node.  Nodes hosting critical
# self-healing components are labeled by 08-configure-monitoring.sh:
#   self-healing-agent.demo/protected=true
# We also exclude control-plane and GPU nodes.

CANDIDATES=$(oc get nodes \
  -l 'node-role.kubernetes.io/worker,!nvidia.com/gpu.present,!node-role.kubernetes.io/master' \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.self-healing-agent\.demo/protected}{"\n"}{end}' 2>/dev/null || true)

WORKER=""
FALLBACK=""
FALLBACK_CRIT=999999

while IFS=' ' read -r NODE_NAME PROTECTED; do
  [ -z "${NODE_NAME}" ] && continue

  if [ "${PROTECTED}" != "true" ]; then
    WORKER="${NODE_NAME}"
    echo "Selected unprotected node: ${WORKER}"
    break
  else
    CRIT=$(oc get pods -A --field-selector="spec.nodeName=${NODE_NAME},status.phase=Running" \
      --no-headers 2>/dev/null | wc -l) || CRIT=999
    echo "  ${NODE_NAME} is protected (${CRIT} running pods)"
    if [ "${CRIT}" -lt "${FALLBACK_CRIT}" ]; then
      FALLBACK="${NODE_NAME}"
      FALLBACK_CRIT="${CRIT}"
    fi
  fi
done <<< "${CANDIDATES}"

if [ -z "${WORKER}" ]; then
  if [ -n "${FALLBACK}" ]; then
    echo ""
    echo "NOTE: All workers are protected. Selecting ${FALLBACK} (fewest pods: ${FALLBACK_CRIT})."
    echo "      The drain will safely reschedule pods before the kubelet is stopped."
    WORKER="${FALLBACK}"
  else
    echo "ERROR: No eligible worker nodes found."
    exit 1
  fi
fi

echo ""
echo "Target worker node: ${WORKER}"
echo ""
echo "Current node status:"
oc get node "${WORKER}" -o wide
echo ""

if [ -t 0 ]; then
  read -rp "Press ENTER to trigger the failure (cordon + drain + stop kubelet on ${WORKER})..."
else
  echo "Non-interactive mode: proceeding with failure trigger on ${WORKER}..."
fi

echo ""
echo "Step 1/3: Cordoning node ${WORKER} (marking unschedulable)..."
oc adm cordon "${WORKER}"

echo ""
echo "Step 2/3: Draining node ${WORKER} (gracefully moving workloads off)..."
oc adm drain "${WORKER}" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --disable-eviction \
  --timeout=120s 2>&1 || echo "  [WARN] Drain completed with warnings (some pods may have been force-deleted)"

echo ""
echo "Step 3/3: Stopping kubelet on ${WORKER}..."
timeout 30 oc debug "node/${WORKER}" --no-tty -- chroot /host systemctl stop kubelet 2>/dev/null || true

oc delete pods -n default -l "run" --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true

echo ""
echo "Verifying node status..."
for i in $(seq 1 12); do
  STATUS=$(oc get node "${WORKER}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "${STATUS}" = "False" ] || [ "${STATUS}" = "Unknown" ]; then
    echo "  [OK] Node ${WORKER} is NotReady"
    break
  fi
  echo "  Waiting for node to become NotReady (attempt ${i}/12)..."
  sleep 5
done

echo ""
echo "The KubeNodeNotReady alert should fire within ~1 minute."
echo "The EDA rulebook will trigger the self-healing workflow (once per 3-hour window)."
echo ""
echo "Watch the node:     oc get node ${WORKER} -w"
echo "Watch alerts:        oc get prometheusrule -A"
echo ""
echo "To clean up:         ./demo/scenarios/01-worker-node-failure/cleanup.sh"
