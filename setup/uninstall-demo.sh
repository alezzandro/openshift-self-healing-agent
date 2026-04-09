#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

ok()   { echo "  [OK] $*"; }
skip() { echo "  [SKIP] $*"; }
warn() { echo "  [WARN] $*"; }

echo "============================================================"
echo "  OpenShift Self-Healing Agent -- Uninstall"
echo "============================================================"
echo ""
echo "This will remove all demo configuration and services while"
echo "preserving operators, subscriptions, and cluster nodes."
echo ""
if [ -t 0 ]; then
  read -rp "Continue? [y/N] " REPLY
  [[ "${REPLY}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi
echo ""

###############################################################################
# 1. Remove monitoring customisations
###############################################################################
echo "1. Removing monitoring customisations..."

oc delete prometheusrule self-healing-demo-overrides -n openshift-monitoring 2>/dev/null \
  && ok "Deleted PrometheusRule self-healing-demo-overrides" \
  || skip "PrometheusRule already absent"

echo "  Restoring default Alertmanager config (removing EDA webhook)..."
oc create secret generic alertmanager-main -n openshift-monitoring \
  --from-literal=alertmanager.yaml="$(cat <<'AM_DEFAULT'
global:
  resolve_timeout: 5m
route:
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: 'default'
receivers:
  - name: 'default'
AM_DEFAULT
)" --dry-run=client -o yaml | oc apply -f - \
  && ok "Alertmanager config restored to defaults" \
  || warn "Could not reset Alertmanager config"

echo "  Removing self-healing-agent.demo/protected label from nodes..."
LABELED_NODES=$(oc get nodes -l self-healing-agent.demo/protected=true \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
for NODE in ${LABELED_NODES}; do
  oc label node "${NODE}" self-healing-agent.demo/protected- 2>/dev/null || true
done
[ -n "${LABELED_NODES}" ] \
  && ok "Removed label from: ${LABELED_NODES}" \
  || skip "No nodes were labeled"
echo ""

###############################################################################
# 2. Remove AAP instance and configuration (keep operator + namespace)
###############################################################################
echo "2. Removing AAP instance and configuration..."

oc delete ansibleautomationplatform aap -n aap --timeout=120s 2>/dev/null \
  && ok "Deleted AnsibleAutomationPlatform CR 'aap'" \
  || skip "AAP instance not found"

echo "  Waiting for AAP operator to clean up managed resources..."
for i in $(seq 1 60); do
  REMAINING=$(oc get all -n aap --no-headers 2>/dev/null | wc -l)
  if [ "${REMAINING}" -le 2 ]; then
    break
  fi
  sleep 5
done

oc delete route aap-hub -n aap 2>/dev/null || true
oc delete pvc --all -n aap --timeout=60s 2>/dev/null || true
oc delete secret aap-admin-password -n aap 2>/dev/null || true
oc delete istag self-healing-ee:latest -n aap 2>/dev/null || true
oc delete is self-healing-ee -n aap 2>/dev/null || true
oc delete sa self-healing-sa -n aap 2>/dev/null || true
ok "AAP namespace cleaned (operator and subscription preserved)"
echo ""

###############################################################################
# 3. Remove MCP servers (delete entire namespace)
###############################################################################
echo "3. Removing MCP servers namespace..."

oc delete namespace self-healing-agent --timeout=120s 2>/dev/null \
  && ok "Deleted namespace self-healing-agent" \
  || skip "Namespace self-healing-agent not found"
echo ""

###############################################################################
# 4. Remove Gitea (delete entire namespace)
###############################################################################
echo "4. Removing Gitea namespace..."

oc delete namespace gitea --timeout=120s 2>/dev/null \
  && ok "Deleted namespace gitea" \
  || skip "Namespace gitea not found"
echo ""

###############################################################################
# 5. Remove RHOAI project workloads (delete entire namespace)
###############################################################################
echo "5. Removing RHOAI project namespace (model serving, LlamaStack, Postgres)..."

oc delete inferenceservice --all -n rhoai-project --timeout=60s 2>/dev/null || true
oc delete llamastackdistribution --all -n rhoai-project --timeout=60s 2>/dev/null || true
sleep 5
oc delete namespace rhoai-project --timeout=180s 2>/dev/null \
  && ok "Deleted namespace rhoai-project" \
  || skip "Namespace rhoai-project not found"
echo ""

###############################################################################
# 6. Remove RHOAI cluster-level configuration (keep operator)
###############################################################################
echo "6. Removing RHOAI cluster-level configuration..."

oc delete datasciencecluster default-dsc --timeout=60s 2>/dev/null \
  && ok "Deleted DataScienceCluster default-dsc" \
  || skip "DataScienceCluster not found"

oc delete hardwareprofile gpu-l4-nvidia -n redhat-ods-applications 2>/dev/null \
  && ok "Deleted HardwareProfile gpu-l4-nvidia" \
  || skip "HardwareProfile not found"

oc delete configmap gen-ai-aa-mcp-servers -n redhat-ods-applications 2>/dev/null \
  && ok "Deleted MCP servers ConfigMap from Gen AI Playground" \
  || skip "MCP ConfigMap not found"

echo "  Resetting OdhDashboardConfig (disable Gen AI Playground)..."
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  --type merge -p '{"spec":{"dashboardConfig":{"disableModelCatalog":true,"genAiStudio":false}}}' 2>/dev/null \
  && ok "Dashboard config reset" \
  || skip "Dashboard config not found"
echo ""

###############################################################################
# 7. Remove Lightspeed configuration (keep operator)
###############################################################################
echo "7. Removing Lightspeed configuration..."

oc delete olsconfig cluster --timeout=60s 2>/dev/null \
  && ok "Deleted OLSConfig cluster" \
  || skip "OLSConfig not found"

oc delete secret proxy-api-keys -n openshift-lightspeed 2>/dev/null \
  && ok "Deleted proxy-api-keys secret" \
  || skip "Secret not found"

oc delete sa self-healing-ols-client -n openshift-lightspeed 2>/dev/null \
  && ok "Deleted ServiceAccount self-healing-ols-client" \
  || skip "ServiceAccount not found"

oc delete secret self-healing-ols-token -n openshift-lightspeed 2>/dev/null \
  && ok "Deleted SA token secret" \
  || skip "Token secret not found"

oc delete networkpolicy allow-aap-to-lightspeed -n openshift-lightspeed 2>/dev/null \
  && ok "Deleted NetworkPolicy allow-aap-to-lightspeed" \
  || skip "NetworkPolicy not found"

oc delete clusterrolebinding self-healing-ols-query-access 2>/dev/null \
  && ok "Deleted ClusterRoleBinding self-healing-ols-query-access" \
  || skip "ClusterRoleBinding not found"
echo ""

###############################################################################
# 8. Revert image registry default route (optional, safe)
###############################################################################
echo "8. Reverting image registry default route..."

oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
  -p '{"spec":{"defaultRoute":false}}' 2>/dev/null \
  && ok "Disabled default route on internal image registry" \
  || skip "Could not patch image registry config"
echo ""

###############################################################################
# 9. Clean up local credential files
###############################################################################
echo "9. Removing local credential files..."

for CRED_FILE in \
  "${SCRIPT_DIR}/.generated-credentials.env" \
  "${SCRIPT_DIR}/.servicenow-credentials.env"; do
  if [ -f "${CRED_FILE}" ]; then
    rm -f "${CRED_FILE}"
    ok "Removed $(basename "${CRED_FILE}")"
  else
    skip "$(basename "${CRED_FILE}") not found"
  fi
done
echo ""

###############################################################################
# 10. Clean up local container images (optional)
###############################################################################
echo "10. Cleaning up local container images..."

for IMG in $(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E 'self-healing-ee|servicenow-mcp|git-mcp' || true); do
  podman rmi "${IMG}" 2>/dev/null && ok "Removed image ${IMG}" || true
done
skip "No matching local images (or podman not available)"
echo ""

###############################################################################
# Summary
###############################################################################
echo "============================================================"
echo "  Uninstall complete"
echo "============================================================"
echo ""
echo "Removed:"
echo "  - AAP instance and configuration (operator preserved)"
echo "  - Gitea namespace and all resources"
echo "  - MCP servers namespace and all resources"
echo "  - RHOAI project (model, LlamaStack, Postgres)"
echo "  - DataScienceCluster, HardwareProfile, Gen AI Playground config"
echo "  - Lightspeed OLSConfig and demo access resources"
echo "  - Monitoring rules and Alertmanager webhook"
echo "  - Node protection labels"
echo "  - Local credential files"
echo ""
echo "Preserved:"
echo "  - All operator subscriptions (AAP, RHOAI, GPU, NFD, Lightspeed)"
echo "  - Operator namespaces (aap, redhat-ods-operator, nvidia-gpu-operator, etc.)"
echo "  - GPU and general worker nodes"
echo "  - Cluster configuration (OAuth, MachineConfig, etc.)"
echo ""
echo "To fully reinstall, run the setup scripts again starting from:"
echo "  ./setup/02-configure-gpu.sh  (if GPU config was not changed)"
echo "  ./setup/03-configure-rhoai.sh"
echo "  ./setup/04-deploy-gitea.sh"
echo "  ..."
