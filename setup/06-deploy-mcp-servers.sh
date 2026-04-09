#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/mcp-servers"
MCP_DIR="${SCRIPT_DIR}/../mcp-servers"

echo "=== Deploying MCP Servers ==="
echo ""

SNOW_CREDS="${SCRIPT_DIR}/.servicenow-credentials.env"
if [ -f "${SNOW_CREDS}" ]; then
  while IFS= read -r line; do
    [[ "${line}" =~ ^#.*$ ]] && continue
    [[ -z "${line}" ]] && continue
    KEY="${line%%=*}"
    VAL="${line#*=}"
    VAL="${VAL#\'}" ; VAL="${VAL%\'}"
    VAL="${VAL#\"}" ; VAL="${VAL%\"}"
    export "${KEY}=${VAL}"
  done < "${SNOW_CREDS}"
  echo "Loaded ServiceNow credentials from ${SNOW_CREDS}"
else
  echo "WARNING: ServiceNow credentials not found. Run 05-configure-servicenow.sh first."
  echo "Continuing with placeholder values..."
fi

echo ""
echo "1. Creating namespace..."
oc apply -f "${MANIFESTS_DIR}/namespace.yaml"
echo ""

echo "2. Building MCP server images via OpenShift BuildConfigs..."

INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

for MCP_NAME in servicenow-mcp git-mcp knowledge-base-mcp; do
  MCP_CONTEXT="${MCP_DIR}/${MCP_NAME}"
  if [ ! -f "${MCP_CONTEXT}/Containerfile" ]; then
    echo "  [ERROR] Containerfile not found: ${MCP_CONTEXT}/Containerfile"
    continue
  fi

  EXISTING_BC=$(oc get bc "${MCP_NAME}" -n self-healing-agent --no-headers 2>/dev/null | wc -l) || EXISTING_BC=0
  if [ "${EXISTING_BC}" -eq 0 ]; then
    echo "  Creating BuildConfig for ${MCP_NAME}..."
    oc new-build --strategy=docker \
      --binary \
      --name="${MCP_NAME}" \
      -n self-healing-agent 2>&1 | grep -E "created|exists|error" || true
    oc patch buildconfig "${MCP_NAME}" -n self-healing-agent --type=merge \
      -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"Containerfile"}}}}' 2>/dev/null || true
  fi

  echo "  Building ${MCP_NAME} from ${MCP_CONTEXT}..."
  oc start-build "${MCP_NAME}" -n self-healing-agent --from-dir="${MCP_CONTEXT}" 2>&1 || true
done

echo "  Waiting for builds to complete (this may take 2-3 minutes)..."
for MCP_NAME in servicenow-mcp git-mcp knowledge-base-mcp; do
  for i in $(seq 1 60); do
    LATEST_BUILD=$(oc get builds -n self-healing-agent -l "buildconfig=${MCP_NAME}" \
      --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${LATEST_BUILD}" ]; then
      sleep 5
      continue
    fi
    PHASE=$(oc get build "${LATEST_BUILD}" -n self-healing-agent \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${PHASE}" = "Complete" ]; then
      echo "  [OK] ${MCP_NAME} build complete"
      break
    elif [ "${PHASE}" = "Failed" ] || [ "${PHASE}" = "Error" ]; then
      echo "  [ERROR] ${MCP_NAME} build failed. Check: oc logs build/${LATEST_BUILD} -n self-healing-agent"
      break
    fi
    if [ "$((i % 6))" -eq 0 ]; then
      echo "  ${MCP_NAME} build phase: ${PHASE:-Pending}..."
    fi
    sleep 5
  done
done
echo ""

echo "3. Creating secrets for MCP servers..."
if [ -n "${SNOW_INSTANCE:-}" ]; then
  oc create secret generic servicenow-mcp-credentials \
    -n self-healing-agent \
    --from-literal=SERVICENOW_INSTANCE_URL="${SNOW_INSTANCE}" \
    --from-literal=SERVICENOW_AUTH_TYPE="basic" \
    --from-literal=SERVICENOW_USERNAME="${SNOW_ADMIN_USERNAME:-admin}" \
    --from-literal=SERVICENOW_PASSWORD="${SNOW_ADMIN_PASSWORD}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "  [OK] ServiceNow MCP credentials secret applied"
else
  echo "  [WARN] SNOW_INSTANCE not set — ServiceNow MCP secret not created"
fi

GITEA_ROUTE=$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -z "${GITEA_ROUTE}" ]; then
  echo "  [ERROR] Gitea route not found. Ensure 04-deploy-gitea.sh has been run."
  exit 1
fi
GITEA_PASS=$(oc get secret gitea-admin-credentials -n gitea -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
if [ -z "${GITEA_PASS}" ]; then
  echo "  [ERROR] Could not read Gitea admin password from secret. Ensure 04-deploy-gitea.sh has been run."
  exit 1
fi
oc create secret generic git-mcp-credentials \
  -n self-healing-agent \
  --from-literal=GITEA_URL="https://${GITEA_ROUTE}" \
  --from-literal=GITEA_USERNAME="gitea_admin" \
  --from-literal=GITEA_PASSWORD="${GITEA_PASS}" \
  --dry-run=client -o yaml | oc apply -f -
echo "  [OK] Git MCP credentials secret applied"
echo ""

echo "4. Deploying MCP server manifests..."
oc apply -f "${MANIFESTS_DIR}/servicenow-mcp.yaml"
oc apply -f "${MANIFESTS_DIR}/git-mcp.yaml"
oc apply -f "${MANIFESTS_DIR}/knowledge-base-mcp.yaml"

echo "  Restarting deployments to pick up secrets..."
oc rollout restart deployment/servicenow-mcp -n self-healing-agent 2>/dev/null || true
oc rollout restart deployment/git-mcp -n self-healing-agent 2>/dev/null || true
oc rollout restart deployment/knowledge-base-mcp -n self-healing-agent 2>/dev/null || true
echo ""

echo "5. Waiting for MCP pods to be ready..."
for pod_label in "servicenow-mcp" "git-mcp" "knowledge-base-mcp"; do
  echo "  Waiting for ${pod_label}..."
  for i in $(seq 1 60); do
    READY=$(oc get pods -n self-healing-agent -l "app=${pod_label}" \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "${READY}" = "True" ]; then
      echo "  [OK] ${pod_label} is running and ready"
      break
    fi
    if [ "$((i % 6))" -eq 0 ]; then
      POD_STATUS=$(oc get pods -n self-healing-agent -l "app=${pod_label}" \
        --no-headers -o custom-columns=STATUS:.status.phase 2>/dev/null || echo "Pending")
      echo "  ${pod_label} status: ${POD_STATUS}..."
    fi
    sleep 5
  done
done

echo ""
echo "=== MCP servers deployed ==="
echo "ServiceNow MCP:      servicenow-mcp.self-healing-agent.svc:8080"
echo "Git MCP:             git-mcp.self-healing-agent.svc:8080"
echo "Knowledge Base MCP:  knowledge-base-mcp.self-healing-agent.svc:8080"
