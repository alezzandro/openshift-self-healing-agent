#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../setup/ensure-authenticated.sh"

echo "=== Cleanup: Node Disk Pressure ==="

WORKERS=$(oc get nodes -l 'node-role.kubernetes.io/worker,!nvidia.com/gpu.present' \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)

CLEANED=0
for WORKER in ${WORKERS}; do
  PRESSURE=$(oc get node "${WORKER}" \
    -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null || echo "")

  if [ "${PRESSURE}" = "True" ]; then
    echo "Node ${WORKER} has DiskPressure. Removing fill file..."
    timeout 60 oc debug "node/${WORKER}" --no-tty -- \
      chroot /host rm -f /var/tmp/self-healing-disk-fill 2>/dev/null || true
    oc delete pods -n default -l "run" --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true
    ((CLEANED++)) || true
  fi
done

if [ "${CLEANED}" -eq 0 ]; then
  echo "No nodes with DiskPressure found."
  echo "Checking all workers for leftover fill files anyway..."
  for WORKER in ${WORKERS}; do
    timeout 30 oc debug "node/${WORKER}" --no-tty -- \
      chroot /host rm -f /var/tmp/self-healing-disk-fill 2>/dev/null || true
    oc delete pods -n default -l "run" --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true
  done
  echo "  Done."
  exit 0
fi

echo ""
echo "Waiting for DiskPressure to clear..."
for i in $(seq 1 60); do
  ALL_CLEAR=true
  for WORKER in ${WORKERS}; do
    PRESSURE=$(oc get node "${WORKER}" \
      -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null || echo "")
    if [ "${PRESSURE}" = "True" ]; then
      ALL_CLEAR=false
      break
    fi
  done
  if ${ALL_CLEAR}; then
    echo "  [OK] All worker nodes have cleared DiskPressure."
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    echo "  Attempt ${i}/60 -- still waiting for pressure to clear..."
  fi
  sleep 5
done

echo ""
echo "Cleanup complete."
oc get nodes -l 'node-role.kubernetes.io/worker' --no-headers
