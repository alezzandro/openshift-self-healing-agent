#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/monitoring"

echo "=== Configuring Monitoring ==="
echo ""

echo "1. Applying PrometheusRule overrides (reduced for: durations)..."
oc apply -f "${MANIFESTS_DIR}/prometheus-rules-override.yaml"
echo ""

echo "2. Configuring Alertmanager routing to EDA webhook..."
EDA_SVC=$(oc get svc cluster-alert-handler -n aap -o name 2>/dev/null || echo "")
if [ -z "${EDA_SVC}" ]; then
  echo "  [WARN] EDA webhook service 'cluster-alert-handler' not found in aap namespace."
  echo "         Ensure the EDA rulebook activation 'Cluster Alert Handler' is running."
  echo "         Applying config anyway -- it will work once the activation starts."
fi
oc apply -f "${MANIFESTS_DIR}/alertmanager-config.yaml"
echo ""

echo "3. Verifying PrometheusRule..."
oc get prometheusrule self-healing-demo-overrides -n openshift-monitoring
echo ""

echo "4. Verifying Alertmanager config..."
oc get secret alertmanager-main -n openshift-monitoring
echo ""

echo "5. Labeling nodes hosting critical self-healing components as protected..."
CRITICAL_NS_LIST="aap rhoai-project self-healing-agent gitea"
LABELED_NODES=""
for NS in ${CRITICAL_NS_LIST}; do
  NODES=$(oc get pods -n "${NS}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep -v '^$' || true)
  for NODE in ${NODES}; do
    if [[ ! " ${LABELED_NODES} " =~ " ${NODE} " ]]; then
      oc label node "${NODE}" self-healing-agent.demo/protected=true --overwrite 2>/dev/null || true
      LABELED_NODES="${LABELED_NODES} ${NODE}"
    fi
  done
done
if [ -n "${LABELED_NODES}" ]; then
  echo "  [OK] Protected nodes:${LABELED_NODES}"
else
  echo "  [WARN] No critical pods found to determine protected nodes."
fi
echo ""

echo "=== Monitoring configuration complete ==="
echo "Alerts KubeNodeNotReady, ClusterOperatorDegraded, NodeFilesystemSpaceFillingUp,"
echo "and MCPDegraded are now configured with 1-minute 'for' durations and will route to EDA."
echo "Nodes hosting critical self-healing workloads are labeled as protected."
