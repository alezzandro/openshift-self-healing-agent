#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/rhoai"

echo "=== Configuring Red Hat OpenShift AI ==="
echo ""

echo "1. Creating DataScienceCluster..."
oc apply -f "${MANIFESTS_DIR}/datasciencecluster.yaml"
echo ""

echo "2. Waiting for DSC to be ready..."
for i in $(seq 1 120); do
  PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "${PHASE}" = "Ready" ]; then
    echo "  [OK] DataScienceCluster is Ready"
    break
  fi
  echo "  Attempt ${i}/120 -- phase: ${PHASE:-Pending}"
  sleep 10
done
echo ""

echo "3. Enabling Model Catalog and Gen AI Playground in dashboard..."
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  --type merge -p '{"spec": {"dashboardConfig": {"disableModelCatalog": false, "genAiStudio": true}}}' 2>/dev/null \
  && echo "  [OK] Model Catalog + Gen AI Playground enabled" \
  || echo "  [WARN] Could not patch dashboard config"
echo ""

echo "4. Creating project namespace..."
oc apply -f "${MANIFESTS_DIR}/namespace.yaml"
echo ""

echo "5. Creating service account..."
oc apply -f "${MANIFESTS_DIR}/model-storage-secret.yaml"
echo ""

echo "6. Creating GPU HardwareProfile..."
oc apply -f "${MANIFESTS_DIR}/hardware-profile.yaml"
echo "  [OK] HardwareProfile gpu-l4-nvidia created"
echo ""

echo "7. Creating vLLM ServingRuntime (Red Hat AI Inference Server)..."
oc apply -f "${MANIFESTS_DIR}/vllm-serving-runtime.yaml"
echo ""

echo "8. Creating InferenceService for Mistral Small 3.1 24B INT4 (OCI ModelCar from Red Hat Model Catalog)..."
oc apply -f "${MANIFESTS_DIR}/inference-service.yaml"
echo ""

echo "9. Waiting for InferenceService to be ready..."
for i in $(seq 1 120); do
  IS_READY=$(oc get inferenceservice mistral-small-3-1-24b -n rhoai-project \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "${IS_READY}" = "True" ]; then
    echo "  [OK] InferenceService is Ready"
    break
  fi
  echo "  Attempt ${i}/120 -- waiting for model deployment..."
  sleep 15
done
echo ""

echo "10. Deploying PostgreSQL for LlamaStack metadata store..."
PG_SECRET_EXISTS=$(oc get secret llamastack-postgres-secret -n rhoai-project -o name 2>/dev/null || echo "")
if [ -z "${PG_SECRET_EXISTS}" ]; then
  PG_PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
  oc create secret generic llamastack-postgres-secret -n rhoai-project \
    --from-literal=password="${PG_PASS}" \
    --from-literal=POSTGRES_PASSWORD="${PG_PASS}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "  [OK] PostgreSQL secret created with generated password"
fi
oc apply -f "${MANIFESTS_DIR}/llamastack-postgres.yaml"
echo "  Waiting for PostgreSQL to be ready..."
for i in $(seq 1 60); do
  PG_READY=$(oc get pods -n rhoai-project -l app=llamastack-postgres \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "${PG_READY}" = "True" ]; then
    echo "  [OK] PostgreSQL is ready"
    break
  fi
  echo "  Attempt ${i}/60 -- waiting..."
  sleep 5
done
echo ""

echo "11. Deploying LlamaStack distribution (rh-dev)..."
oc apply -f "${MANIFESTS_DIR}/llamastack-distribution.yaml"
echo ""

echo "12. Waiting for LlamaStack to be ready..."
for i in $(seq 1 60); do
  LS_PHASE=$(oc get llamastackdistribution self-healing-agent -n rhoai-project \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "${LS_PHASE}" = "Ready" ]; then
    echo "  [OK] LlamaStack is Ready"
    break
  fi
  echo "  Attempt ${i}/60 -- phase: ${LS_PHASE:-Pending}"
  sleep 10
done

echo ""
echo "13. Creating NetworkPolicy to allow AAP namespace access to LlamaStack..."
cat <<'NETPOL_EOF' | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-aap-to-llamastack
  namespace: rhoai-project
spec:
  podSelector:
    matchLabels:
      app: llama-stack
      app.kubernetes.io/instance: self-healing-agent
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: aap
    ports:
    - port: 8321
      protocol: TCP
  policyTypes:
  - Ingress
NETPOL_EOF
echo ""

echo ""
echo "14. Configuring OpenShift Lightspeed (RAG over OCP 4.21 documentation)..."
  echo "  Creating OLSConfig CR pointing to the local Mistral Small 3.1 24B model..."
OLS_MANIFESTS="${SCRIPT_DIR}/../manifests/operators"
oc apply -f "${OLS_MANIFESTS}/lightspeed-olsconfig.yaml"
echo ""

echo "  Waiting for Lightspeed to be ready..."
for i in $(seq 1 60); do
  OLS_PHASE=$(oc get olsconfig cluster \
    -o jsonpath='{.status.overallStatus}' 2>/dev/null || echo "")
  if [ "${OLS_PHASE}" = "Ready" ]; then
    echo "  [OK] OpenShift Lightspeed is Ready"
    break
  fi
  echo "  Attempt ${i}/60 -- status: ${OLS_PHASE:-Pending}"
  sleep 10
done
echo ""

echo "15. Setting up self-healing agent access to Lightspeed..."
echo "  The workflow queries Lightspeed's pre-built OCP 4.21 docs index"
echo "  (18,000+ document chunks, all-mpnet-base-v2 embeddings) at runtime."
echo ""

OLS_NS="openshift-lightspeed"
OLS_SA="self-healing-ols-client"
OLS_SECRET="self-healing-ols-token"

echo "  Creating ServiceAccount '${OLS_SA}' in ${OLS_NS}..."
oc create sa "${OLS_SA}" -n "${OLS_NS}" --dry-run=client -o yaml | oc apply -f -

echo "  Binding SA to lightspeed-operator-query-access ClusterRole..."
oc create clusterrolebinding self-healing-ols-query-access \
  --clusterrole=lightspeed-operator-query-access \
  "--serviceaccount=${OLS_NS}:${OLS_SA}" \
  --dry-run=client -o yaml | oc apply -f -

echo "  Creating long-lived token secret..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${OLS_SECRET}
  namespace: ${OLS_NS}
  annotations:
    kubernetes.io/service-account.name: ${OLS_SA}
type: kubernetes.io/service-account-token
EOF
sleep 3

OLS_TOKEN=$(oc get secret "${OLS_SECRET}" -n "${OLS_NS}" \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
if [ -n "${OLS_TOKEN}" ]; then
  echo "  [OK] OLS token ready (${#OLS_TOKEN} chars)"
else
  echo "  [WARN] Token not yet populated — the workflow will read it at runtime"
fi

echo "  Creating NetworkPolicy to allow AAP → Lightspeed traffic..."
cat <<'NETPOL2_EOF' | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-aap-to-lightspeed
  namespace: openshift-lightspeed
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: application-server
      app.kubernetes.io/managed-by: lightspeed-operator
      app.kubernetes.io/name: lightspeed-service-api
      app.kubernetes.io/part-of: openshift-lightspeed
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: aap
    ports:
    - port: 8443
      protocol: TCP
  policyTypes:
  - Ingress
NETPOL2_EOF

echo "  Verifying Lightspeed service is reachable..."
OLS_STATUS=$(oc exec -n "${OLS_NS}" deploy/lightspeed-app-server \
  -c lightspeed-service-api -- curl -sk https://localhost:8443/readiness 2>/dev/null || echo "{}")
if echo "${OLS_STATUS}" | python3 -c "import sys,json; assert json.load(sys.stdin).get('ready')==True" 2>/dev/null; then
  echo "  [OK] Lightspeed service is ready"
else
  echo "  [WARN] Lightspeed service readiness check returned: ${OLS_STATUS}"
fi
echo ""

echo ""
echo "16. Registering MCP servers for the Gen AI Playground..."
echo "  Creating ConfigMap in redhat-ods-applications with available MCP server definitions..."
cat <<'MCP_EOF' | oc apply -f -
kind: ConfigMap
apiVersion: v1
metadata:
  name: gen-ai-aa-mcp-servers
  namespace: redhat-ods-applications
data:
  ServiceNow-MCP-Server: |
    {
      "url": "http://servicenow-mcp.self-healing-agent.svc:8080/mcp",
      "description": "The ServiceNow MCP server provides tools for interacting with ServiceNow ITSM. It can create, update, and query incidents, manage work notes, and track incident resolution. Use this to integrate automated incident management into your AI workflows."
    }
  Git-MCP-Server: |
    {
      "url": "http://git-mcp.self-healing-agent.svc:8080/mcp",
      "description": "The Git MCP server enables interaction with Gitea repositories. It can create, read, and update files in Git repositories, manage branches, and commit changes. Use this to store and retrieve Ansible remediation playbooks generated by the self-healing agent."
    }
MCP_EOF
echo "  [OK] MCP servers registered for Gen AI Playground"
echo ""

LS_URL="http://self-healing-agent-service.rhoai-project.svc.cluster.local:8321"
echo ""
echo "=== OpenShift AI configuration complete ==="
echo "Mistral Small 3.1 24B INT4 (from Red Hat Model Catalog) + LlamaStack deployed in namespace 'rhoai-project'"
echo "LlamaStack service URL: ${LS_URL}"
echo "RAG source: OpenShift Lightspeed (OCP 4.21 product documentation)"
echo "Gen AI Playground: enabled (navigate to Gen AI Studio in the OpenShift AI dashboard)"
