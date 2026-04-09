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

DISK_TOTAL_KB=$(oc debug "node/${WORKER}" --no-tty -- chroot /host df /var/tmp 2>/dev/null \
  | awk 'NR==2{print $2}' || echo "0")
oc delete pods -n default -l "run" --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true

DISK_TOTAL_GB=$(( DISK_TOTAL_KB / 1024 / 1024 ))
FILL_GB=$(( DISK_TOTAL_GB * 85 / 100 ))
if [ "${FILL_GB}" -lt 5 ]; then
  FILL_GB=40
fi

echo "Node root disk: ~${DISK_TOTAL_GB} GB.  Will fill ~${FILL_GB} GB to trigger DiskPressure."
echo ""

if [ -t 0 ]; then
  read -rp "Press ENTER to trigger the failure (write ${FILL_GB} GB to ${WORKER})..."
else
  echo "Non-interactive mode: proceeding with disk fill on ${WORKER}..."
fi

echo ""
echo "Creating ${FILL_GB} GB file on ${WORKER} at /var/tmp/self-healing-disk-fill..."
echo "(This may take 1-3 minutes depending on disk speed)"
timeout 300 oc debug "node/${WORKER}" --no-tty -- \
  chroot /host dd if=/dev/zero of=/var/tmp/self-healing-disk-fill \
  bs=1M count=$(( FILL_GB * 1024 )) status=progress 2>&1 | tail -3 || true
oc delete pods -n default -l "run" --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true

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
echo "The NodeFilesystemSpaceFillingUp alert should fire within ~1 minute."
echo "The EDA rulebook will trigger the self-healing workflow."
echo ""
echo "Watch:    oc get node ${WORKER} -o jsonpath='{.status.conditions}' | python3 -m json.tool"
echo "Console:  Observe > Alerting > NodeFilesystemSpaceFillingUp"
echo ""
echo "To clean up:  ./demo/scenarios/03-node-disk-pressure/cleanup.sh"
