#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../setup/ensure-authenticated.sh"

echo "=== Scenario 3: Node Disk Pressure ==="
echo "This will fill a worker node's filesystem with a large temporary file,"
echo "causing the kubelet to report DiskPressure and triggering the"
echo "NodeFilesystemSpaceFillingUp alert."
echo ""

PROTECTED_NAMESPACES="aap rhoai-project self-healing-agent gitea openshift-operators"

ALL_WORKERS=$(oc get nodes \
  -l 'node-role.kubernetes.io/worker,!nvidia.com/gpu.present' \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)

if [ -z "${ALL_WORKERS}" ]; then
  echo "ERROR: No non-GPU worker nodes found."
  exit 1
fi

WORKER=""
BEST_CANDIDATE=""
BEST_POD_COUNT=999999

for CANDIDATE in ${ALL_WORKERS}; do
  echo "Checking node ${CANDIDATE} for critical workloads..."
  TOTAL_CRITICAL=0
  HAS_CRITICAL=false
  for NS in ${PROTECTED_NAMESPACES}; do
    COUNT=$(oc get pods -n "${NS}" --field-selector="spec.nodeName=${CANDIDATE},status.phase=Running" --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "${COUNT}" -gt 0 ]; then
      echo "  Found ${COUNT} running pod(s) in namespace '${NS}'"
      TOTAL_CRITICAL=$((TOTAL_CRITICAL + COUNT))
      HAS_CRITICAL=true
    fi
  done

  if [ "${HAS_CRITICAL}" = "false" ]; then
    WORKER="${CANDIDATE}"
    echo "  No critical workloads. Selected: ${WORKER}"
    break
  else
    echo "  Total critical pods: ${TOTAL_CRITICAL}"
    if [ "${TOTAL_CRITICAL}" -lt "${BEST_POD_COUNT}" ]; then
      BEST_POD_COUNT="${TOTAL_CRITICAL}"
      BEST_CANDIDATE="${CANDIDATE}"
    fi
  fi
done

if [ -z "${WORKER}" ]; then
  echo ""
  echo "NOTE: All workers host critical pods. Selecting the one with fewest (${BEST_POD_COUNT})."
  WORKER="${BEST_CANDIDATE}"
  echo "Selected: ${WORKER}"
fi

echo ""
echo "Target worker node: ${WORKER}"
echo ""

MCD_POD=$(oc get pods -n openshift-machine-config-operator \
  -l k8s-app=machine-config-daemon \
  --field-selector="spec.nodeName=${WORKER}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

DISK_INFO=$(oc exec -n openshift-machine-config-operator "${MCD_POD}" -- \
  chroot /rootfs df /var/tmp 2>/dev/null | awk 'NR==2{print $2, $3}' || echo "0 0")
DISK_TOTAL_KB=$(echo "${DISK_INFO}" | awk '{print $1}')
DISK_USED_KB=$(echo "${DISK_INFO}" | awk '{print $2}')

DISK_TOTAL_GB=$(( DISK_TOTAL_KB / 1024 / 1024 ))
DISK_USED_GB=$(( DISK_USED_KB / 1024 / 1024 ))
TARGET_USED_GB=$(( DISK_TOTAL_GB * 92 / 100 ))
FILL_GB=$(( TARGET_USED_GB - DISK_USED_GB ))
if [ "${FILL_GB}" -lt 5 ]; then
  FILL_GB=5
fi

echo "Node root disk: ~${DISK_TOTAL_GB} GB (${DISK_USED_GB} GB used)."
echo "Will allocate ~${FILL_GB} GB to reach ~92% usage and trigger DiskPressure."
echo ""

if [ -t 0 ]; then
  read -rp "Press ENTER to trigger the failure (allocate ${FILL_GB} GB on ${WORKER})..."
else
  echo "Non-interactive mode: proceeding with disk fill on ${WORKER}..."
fi

echo ""
echo "Allocating ${FILL_GB} GB on ${WORKER} at /var/tmp/self-healing-disk-fill..."
echo "(Using fallocate -- this should complete in seconds)"
oc exec -n openshift-machine-config-operator "${MCD_POD}" -- \
  chroot /rootfs fallocate -l "${FILL_GB}G" /var/tmp/self-healing-disk-fill 2>&1 || true

echo ""
echo "Verifying disk pressure on node..."
for i in $(seq 1 24); do
  PRESSURE=$(oc get node "${WORKER}" \
    -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null || echo "")
  if [ "${PRESSURE}" = "True" ]; then
    echo "  [OK] Node ${WORKER} is reporting DiskPressure"
    break
  fi
  echo "  Attempt ${i}/24 -- DiskPressure=${PRESSURE:-pending} (kubelet updates every ~30s)"
  sleep 10
done

echo ""
oc get node "${WORKER}" -o wide
echo ""
echo "The KubeNodePressure (DiskPressure) alert fires after ~10 minutes."
echo "The EDA rulebook will trigger the self-healing workflow automatically."
echo ""
echo "Watch:    oc get node ${WORKER} -o jsonpath='{.status.conditions}' | python3 -m json.tool"
echo "Console:  Observe > Alerting > KubeNodePressure"
echo ""
echo "To clean up:  ./demo/scenarios/03-node-disk-pressure/cleanup.sh"
