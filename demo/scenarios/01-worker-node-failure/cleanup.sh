#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../setup/ensure-authenticated.sh"

echo "=== Cleanup: Worker Node Failure ==="

# Find the NotReady or cordoned worker (the one we triggered)
WORKER=$(oc get nodes -l 'node-role.kubernetes.io/worker,!nvidia.com/gpu.present' \
  --no-headers -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,SCHED:.spec.unschedulable' \
  | grep -E '(False|Unknown|true)' | awk '{print $1}' | head -1 || true)

if [ -z "${WORKER}" ]; then
  echo "No NotReady or cordoned worker node found. Nothing to clean up."
  exit 0
fi

echo "Target worker node: ${WORKER}"
echo ""

# Try oc debug to restart kubelet (may fail if kubelet is fully down)
echo "Step 1/4: Attempting to restart kubelet via oc debug..."
timeout 30 oc debug "node/${WORKER}" --no-tty -- chroot /host systemctl start kubelet 2>/dev/null && KUBELET_STARTED=true || KUBELET_STARTED=false
oc delete pods -n default -l "run" --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true

if [ "${KUBELET_STARTED}" = "true" ]; then
  echo "  [OK] Kubelet restart command sent"
else
  echo "  [INFO] Could not restart kubelet via oc debug (node kubelet is down)."
  echo "         Deleting the machine to let MachineSet recreate it."
  MACHINE=$(oc get machines -n openshift-machine-api -o json | python3 -c "
import sys,json
machines = json.load(sys.stdin).get('items',[])
for m in machines:
    node_ref = m.get('status',{}).get('nodeRef',{}).get('name','')
    if node_ref == '${WORKER}':
        print(m['metadata']['name'])
        break
" 2>/dev/null || echo "")
  if [ -n "${MACHINE}" ]; then
    echo "  Deleting machine: ${MACHINE}"
    oc delete machine "${MACHINE}" -n openshift-machine-api --wait=false 2>/dev/null || true
    echo "  [OK] Machine deletion initiated. MachineSet will create a replacement."
    echo "  The new node will be Ready in ~5 minutes."
  else
    echo "  [WARN] Could not find machine for node ${WORKER}."
    echo "  Manual intervention required."
  fi
fi

echo ""
echo "Step 2/4: Waiting for node recovery..."
RECOVERED=false
for i in $(seq 1 60); do
  STATUS=$(oc get node "${WORKER}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Deleted")
  if [ "${STATUS}" = "True" ]; then
    echo "  [OK] Node ${WORKER} is Ready."
    RECOVERED=true
    break
  fi
  if [ "${STATUS}" = "Deleted" ]; then
    echo "  Node ${WORKER} has been removed. Waiting for replacement..."
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    echo "  Attempt ${i}/60 -- node status: ${STATUS}"
  fi
  sleep 5
done

if [ "${RECOVERED}" = "false" ]; then
  echo ""
  echo "Step 3/4: Waiting for replacement node from MachineSet..."
  for i in $(seq 1 60); do
    NEW_NODES=$(oc get nodes -l 'node-role.kubernetes.io/worker,!nvidia.com/gpu.present' \
      --no-headers -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null \
      | grep "True" | wc -l)
    EXPECTED=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=':spec.replicas' | awk '{s+=$1}END{print s}' 2>/dev/null || echo "3")
    if [ "${NEW_NODES}" -ge 3 ]; then
      echo "  [OK] ${NEW_NODES} healthy worker nodes available."
      break
    fi
    if [ "$((i % 6))" -eq 0 ]; then
      echo "  Attempt ${i}/60 -- ${NEW_NODES} healthy workers (waiting for ${EXPECTED})..."
    fi
    sleep 10
  done
fi

echo ""
echo "Step 4/4: Uncordoning any cordoned nodes..."
for N in $(oc get nodes --no-headers -o custom-columns='NAME:.metadata.name,SCHED:.spec.unschedulable' | grep "true" | awk '{print $1}'); do
  oc adm uncordon "${N}" 2>/dev/null && echo "  Uncordoned: ${N}" || true
done

echo ""
echo "Cleanup complete."
oc get nodes --no-headers
