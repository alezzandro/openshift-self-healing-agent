#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/operators"

echo "=== Configuring GPU Support ==="
echo ""

echo "1. Creating NodeFeatureDiscovery instance..."
oc apply -f "${MANIFESTS_DIR}/nfd-instance.yaml"
echo ""

echo "2. Waiting for NFD worker pods..."
for i in $(seq 1 60); do
  NFD_READY=$(oc get pods -n openshift-nfd -l app.kubernetes.io/component=worker \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "${NFD_READY}" -gt 0 ]; then
    echo "  [OK] NFD worker pods running: ${NFD_READY}"
    break
  fi
  echo "  Attempt ${i}/60 -- waiting..."
  sleep 5
done
echo ""

echo "3. Creating GPU ClusterPolicy..."
oc apply -f "${MANIFESTS_DIR}/gpu-cluster-policy.yaml"
echo ""

echo "4. Waiting for GPU nodes to be labeled..."
for i in $(seq 1 120); do
  GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l)
  if [ "${GPU_NODES}" -gt 0 ]; then
    echo "  [OK] GPU nodes detected: ${GPU_NODES}"
    oc get nodes -l nvidia.com/gpu.present=true
    break
  fi
  echo "  Attempt ${i}/120 -- waiting for GPU detection..."
  sleep 10
done

echo ""
echo "=== GPU configuration complete ==="
