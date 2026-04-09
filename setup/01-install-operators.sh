#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/operators"

echo "=== Installing Operators ==="
echo ""

wait_for_namespace() {
  local ns="$1"
  local timeout="${2:-30}"
  for i in $(seq 1 $((timeout / 2))); do
    if oc get namespace "${ns}" &>/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "  [WARN] Namespace '${ns}' not ready within ${timeout}s"
  return 1
}

wait_for_csv() {
  local namespace="$1"
  local name_pattern="$2"
  local timeout="${3:-300}"

  echo "  Waiting for CSV matching '${name_pattern}' in namespace '${namespace}'..."
  for i in $(seq 1 $((timeout / 5))); do
    CSV_NAME=$(oc get csv -n "${namespace}" --no-headers 2>/dev/null | grep "${name_pattern}" | head -1 || echo "")
    if [ -n "${CSV_NAME}" ]; then
      PHASE=$(echo "${CSV_NAME}" | awk '{print $NF}')
      if [ "${PHASE}" = "Succeeded" ]; then
        echo "  [OK] CSV ready: $(echo "${CSV_NAME}" | awk '{print $1}')"
        return 0
      fi
    fi
    sleep 5
  done
  echo "  [WARN] CSV not ready within ${timeout}s"
  return 1
}

echo "1. Creating operator namespaces..."
oc apply -f "${MANIFESTS_DIR}/aap-namespace.yaml"
oc create namespace redhat-ods-operator --dry-run=client -o yaml | oc apply -f -
oc create namespace openshift-nfd --dry-run=client -o yaml | oc apply -f -
oc create namespace nvidia-gpu-operator --dry-run=client -o yaml | oc apply -f -
oc create namespace openshift-lightspeed --dry-run=client -o yaml | oc apply -f -
echo "  Waiting for namespaces to be active..."
wait_for_namespace "aap"
wait_for_namespace "redhat-ods-operator"
wait_for_namespace "openshift-nfd"
wait_for_namespace "nvidia-gpu-operator"
wait_for_namespace "openshift-lightspeed"
echo "  [OK] All namespaces ready"
echo ""

echo "2. Installing AAP 2.6 Operator..."
oc apply -f "${MANIFESTS_DIR}/aap-operator-group.yaml"
oc apply -f "${MANIFESTS_DIR}/aap-subscription.yaml"
echo ""

echo "3. Installing OpenShift AI Operator..."
oc apply -f "${MANIFESTS_DIR}/rhoai-subscription.yaml"
echo ""

echo "4. Installing Node Feature Discovery Operator..."
oc apply -f "${MANIFESTS_DIR}/nfd-subscription.yaml"
echo ""

echo "5. Installing NVIDIA GPU Operator..."
oc apply -f "${MANIFESTS_DIR}/gpu-operator-subscription.yaml"
echo ""

echo "6. Installing OpenShift Lightspeed Operator..."
oc apply -f "${MANIFESTS_DIR}/lightspeed-subscription.yaml"
echo ""

echo "Waiting for operators to install..."
echo ""

wait_for_csv "aap" "aap-operator" 600 || true
wait_for_csv "redhat-ods-operator" "rhods-operator" 300 || true
wait_for_csv "openshift-nfd" "nfd" 300 || true
wait_for_csv "nvidia-gpu-operator" "gpu-operator" 300 || true
wait_for_csv "openshift-lightspeed" "lightspeed-operator" 300 || true

echo ""
echo "=== Operator installation initiated ==="
echo "Run 'oc get csv -A' to verify all operators are in Succeeded state."
