#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "============================================================"
echo "  OpenShift Self-Healing Agent -- Service Credentials"
echo "============================================================"
echo ""

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "unknown")
API_SERVER=$(oc whoami --show-server 2>/dev/null || echo "unknown")

echo "--- OpenShift Cluster ---"
echo "  Console:    https://console-openshift-console.${CLUSTER_DOMAIN}"
echo "  API Server: ${API_SERVER}"
echo "  User:       $(oc whoami 2>/dev/null || echo 'unknown')"
echo ""

AAP_ROUTE=$(oc get route aap -n aap -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
AAP_PASS=$(oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
if [ -n "${AAP_ROUTE}" ]; then
  echo "--- Red Hat Ansible Automation Platform ---"
  echo "  Gateway URL: https://${AAP_ROUTE}"

  CTRL_ROUTE=$(oc get route aap-controller -n aap -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  [ -n "${CTRL_ROUTE}" ] && echo "  Controller:  https://${CTRL_ROUTE}"

  EDA_ROUTE=$(oc get route aap-eda -n aap -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  [ -n "${EDA_ROUTE}" ] && echo "  EDA:         https://${EDA_ROUTE}"

  HUB_ROUTE=$(oc get route aap-hub -n aap -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  [ -n "${HUB_ROUTE}" ] && echo "  Hub:         https://${HUB_ROUTE}"

  echo "  Username:    admin"
  echo "  Password:    ${AAP_PASS}"
else
  echo "--- Red Hat Ansible Automation Platform ---"
  echo "  [NOT DEPLOYED]"
fi
echo ""

RHOAI_ROUTE=$(oc get route data-science-gateway -n openshift-ingress -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "${RHOAI_ROUTE}" ]; then
  RHOAI_ROUTE=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
fi
if [ -z "${RHOAI_ROUTE}" ]; then
  RHOAI_ROUTE=$(oc get route -n redhat-ods-applications -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
fi
RHOAI_DSC=$(oc get datasciencecluster -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "${RHOAI_DSC}" ]; then
  echo "--- Red Hat OpenShift AI ---"
  if [ -n "${RHOAI_ROUTE}" ]; then
    echo "  Dashboard:   https://${RHOAI_ROUTE}"
  else
    echo "  Dashboard:   (no route -- access via OpenShift Console > Applications)"
  fi
  echo "  Auth:        OpenShift credentials (same as cluster login)"

  while IFS= read -r line; do
    ISVC_NS=$(echo "${line}" | awk '{print $1}')
    ISVC_NAME=$(echo "${line}" | awk '{print $2}')
    ISVC_URL=$(echo "${line}" | awk '{print $3}')
    ISVC_READY=$(echo "${line}" | awk '{print $4}')
    echo "  Model:       ${ISVC_NAME} (ns: ${ISVC_NS}, ready: ${ISVC_READY})"
    [ -n "${ISVC_URL}" ] && echo "  Inference:   ${ISVC_URL}"
  done < <(oc get inferenceservice -A --no-headers 2>/dev/null)
else
  echo "--- Red Hat OpenShift AI ---"
  echo "  [NOT DEPLOYED]"
fi
echo ""

GITEA_ROUTE=$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
GITEA_PASS=$(oc get secret gitea-admin-credentials -n gitea -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
if [ -n "${GITEA_ROUTE}" ]; then
  echo "--- Gitea Git Server ---"
  echo "  URL:         https://${GITEA_ROUTE}"
  echo "  Repo:        https://${GITEA_ROUTE}/gitea_admin/remediation-playbooks"
  echo "  Username:    gitea_admin"
  echo "  Password:    ${GITEA_PASS}"
else
  echo "--- Gitea Git Server ---"
  echo "  [NOT DEPLOYED]"
fi
echo ""

SNOW_CREDS="${SCRIPT_DIR}/.servicenow-credentials.env"
if [ -f "${SNOW_CREDS}" ]; then
  while IFS= read -r line; do
    [[ "${line}" =~ ^#.*$ ]] && continue
    [[ -z "${line}" ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    value="${value#\'}" ; value="${value%\'}"
    value="${value#\"}" ; value="${value%\"}"
    export "${key}=${value}"
  done < "${SNOW_CREDS}"
  echo "--- ServiceNow ---"
  echo "  Instance:       ${SNOW_INSTANCE:-unknown}"
  echo "  Auth method:    Admin + impersonation (work notes attributed to service accounts)"
  echo "  Admin User:     ${SNOW_ADMIN_USERNAME:-admin}"
  echo "  Admin Pass:     ${SNOW_ADMIN_PASSWORD:-<see .servicenow-credentials.env>}"
  echo "  AAP Account:    svc-aap-automation (sys_id: ${SNOW_AAP_USER_SYSID:-unknown})"
  echo "  AI Account:     svc-ai-agent (sys_id: ${SNOW_AI_USER_SYSID:-unknown})"
else
  echo "--- ServiceNow ---"
  echo "  [CREDENTIALS NOT FOUND -- run 05-configure-servicenow.sh first]"
fi
echo ""

SNOW_MCP_ROUTE=$(oc get route servicenow-mcp -n self-healing-agent -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
GIT_MCP_ROUTE=$(oc get route git-mcp -n self-healing-agent -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
SNOW_MCP_SVC=$(oc get svc servicenow-mcp -n self-healing-agent -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
GIT_MCP_SVC=$(oc get svc git-mcp -n self-healing-agent -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

echo "--- MCP Servers ---"
if [ -n "${SNOW_MCP_SVC}" ]; then
  echo "  ServiceNow MCP:"
  [ -n "${SNOW_MCP_ROUTE}" ] && echo "    External:  https://${SNOW_MCP_ROUTE}"
  echo "    Internal:  http://servicenow-mcp.self-healing-agent.svc:8080"
else
  echo "  ServiceNow MCP: [NOT DEPLOYED]"
fi
if [ -n "${GIT_MCP_SVC}" ]; then
  echo "  Git MCP:"
  [ -n "${GIT_MCP_ROUTE}" ] && echo "    External:  https://${GIT_MCP_ROUTE}"
  echo "    Internal:  http://git-mcp.self-healing-agent.svc:8080"
else
  echo "  Git MCP:        [NOT DEPLOYED]"
fi
echo ""

echo "--- Quick Commands ---"
echo "  Refresh this info:  ./setup/show-credentials.sh"
echo "  AAP password:       oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d"
echo "  Gitea password:     oc get secret gitea-admin-credentials -n gitea -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "============================================================"
