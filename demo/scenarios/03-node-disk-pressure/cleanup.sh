#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../setup/ensure-authenticated.sh"

echo "=== Cleanup: Node Disk Pressure ==="

WORKERS=$(oc get nodes -l 'node-role.kubernetes.io/worker,!nvidia.com/gpu.present' \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)

CLEANED=0
for WORKER in ${WORKERS}; do
  MCD_POD=$(oc get pods -n openshift-machine-config-operator \
    -l k8s-app=machine-config-daemon \
    --field-selector="spec.nodeName=${WORKER}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -z "${MCD_POD}" ] && continue

  HAS_FILE=$(oc exec -n openshift-machine-config-operator "${MCD_POD}" -- \
    chroot /rootfs ls /var/tmp/self-healing-disk-fill 2>/dev/null && echo "yes" || echo "no")

  PRESSURE=$(oc get node "${WORKER}" \
    -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null || echo "")

  if [ "${PRESSURE}" = "True" ] || [ "${HAS_FILE}" = "yes" ]; then
    echo "Node ${WORKER}: DiskPressure=${PRESSURE}, fill file exists=${HAS_FILE}. Removing..."
    oc exec -n openshift-machine-config-operator "${MCD_POD}" -- \
      chroot /rootfs rm -f /var/tmp/self-healing-disk-fill /var/tmp/self-healing-disk-fill-2 /var/tmp/self-healing-disk-fill-3 2>/dev/null || true
    ((CLEANED++)) || true
  fi
done

if [ "${CLEANED}" -eq 0 ]; then
  echo "No nodes with DiskPressure or fill files found."
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
