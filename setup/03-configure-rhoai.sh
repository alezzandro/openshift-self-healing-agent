#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/rhoai"
CREDS_FILE="${SCRIPT_DIR}/.generated-credentials.env"

# ── Credential helper: generate once, persist, reuse ─────────────────────────
load_or_generate_pg_password() {
  if [ -f "${CREDS_FILE}" ]; then
    local existing
    existing=$(grep '^LLAMASTACK_PG_PASSWORD=' "${CREDS_FILE}" 2>/dev/null | head -1 || true)
    if [ -n "${existing}" ]; then
      PG_PASS="${existing#*=}"
      PG_PASS="${PG_PASS#\'}"; PG_PASS="${PG_PASS%\'}"
      if [ -n "${PG_PASS}" ]; then
        echo "  Reusing LlamaStack Postgres password from ${CREDS_FILE}"
        return
      fi
    fi
  fi
  PG_PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)"
  echo "LLAMASTACK_PG_PASSWORD='${PG_PASS}'" >> "${CREDS_FILE}"
  chmod 0600 "${CREDS_FILE}"
  echo "  Generated new LlamaStack Postgres password → saved to ${CREDS_FILE}"
}

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

echo "7. Creating vLLM NVIDIA GPU ServingRuntime for KServe..."
VLLM_TEMPLATE_NAME=$(oc get template -n redhat-ods-applications -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -i 'vllm.*cuda' | head -1 || true)
if [ -n "${VLLM_TEMPLATE_NAME}" ]; then
  echo "  Detected platform template: ${VLLM_TEMPLATE_NAME}"
  TEMPLATE_DISPLAY=$(oc get template "${VLLM_TEMPLATE_NAME}" -n redhat-ods-applications \
    -o jsonpath='{.objects[0].metadata.annotations.openshift\.io/display-name}' 2>/dev/null || echo "")
  if [ -z "${TEMPLATE_DISPLAY}" ]; then
    TEMPLATE_DISPLAY="vLLM NVIDIA GPU ServingRuntime for KServe"
  fi
  TMP_SR=$(mktemp)
  sed \
    -e "s|opendatahub.io/template-name:.*|opendatahub.io/template-name: ${VLLM_TEMPLATE_NAME}|" \
    -e "s|opendatahub.io/template-display-name:.*|opendatahub.io/template-display-name: ${TEMPLATE_DISPLAY}|" \
    "${MANIFESTS_DIR}/vllm-serving-runtime.yaml" > "${TMP_SR}"
  oc apply -f "${TMP_SR}"
  rm -f "${TMP_SR}"
else
  echo "  No platform vLLM CUDA template found — using manifest defaults"
  oc apply -f "${MANIFESTS_DIR}/vllm-serving-runtime.yaml"
fi
if oc get servingruntime vllm-runtime -n rhoai-project &>/dev/null; then
  echo "  Removing legacy 'vllm-runtime' (replaced by 'vllm-cuda-runtime')..."
  oc delete servingruntime vllm-runtime -n rhoai-project 2>/dev/null || true
fi
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
load_or_generate_pg_password
oc create secret generic llamastack-postgres-secret -n rhoai-project \
  --from-literal=password="${PG_PASS}" \
  --from-literal=POSTGRES_PASSWORD="${PG_PASS}" \
  --dry-run=client -o yaml | oc apply -f -
echo "  [OK] PostgreSQL secret applied"
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

echo "  Creating NetworkPolicy to allow MCP servers (self-healing-agent ns) access to LlamaStack..."
cat <<'NETPOL2_EOF' | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-mcp-servers-to-llamastack
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
          kubernetes.io/metadata.name: self-healing-agent
    ports:
    - port: 8321
      protocol: TCP
  policyTypes:
  - Ingress
NETPOL2_EOF
echo ""

echo ""
echo "14. Configuring OpenShift Lightspeed (RAG over OCP 4.21 documentation)..."
echo "  Creating proxy-api-keys secret for OLS → vLLM connection..."
oc create secret generic proxy-api-keys -n openshift-lightspeed \
  --from-literal=apitoken="no-auth-needed-for-local-vllm" \
  --dry-run=client -o yaml | oc apply -f -
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
  Knowledge-Base-MCP-Server: |
    {
      "url": "http://knowledge-base-mcp.self-healing-agent.svc:8080/mcp",
      "description": "The Knowledge Base MCP server provides access to the operational knowledge base containing runbooks, remediation procedures, and reference patterns for OpenShift cluster operations. Use 'search_knowledge_base' to find approved remediation steps for alerts, and 'list_knowledge_base_documents' to see available runbooks."
    }
MCP_EOF
echo "  [OK] MCP servers registered for Gen AI Playground"
echo ""

LS_URL="http://self-healing-agent-service.rhoai-project.svc.cluster.local:8321"

###############################################################################
# 17. Create operational knowledge base vector store
###############################################################################
echo "17. Creating operational knowledge base (RAG vector store)..."

KB_DIR="${SCRIPT_DIR}/../knowledge-base"
KB_VS_NAME="ops-knowledge-base"
KB_EMBEDDING_MODEL="sentence-transformers/ibm-granite/granite-embedding-125m-english"
LS_DEPLOY_NAME="self-healing-agent"

_ls_curl() {
  oc exec -n rhoai-project "deploy/${LS_DEPLOY_NAME}" -- curl -sk "$@" 2>/dev/null
}

echo "  Checking for existing vector store '${KB_VS_NAME}'..."
EXISTING_VS_ID=$(_ls_curl "http://localhost:8321/v1/vector_stores" \
  | python3 -c "
import sys, json
for vs in json.load(sys.stdin).get('data', []):
    if vs.get('name') == '${KB_VS_NAME}':
        print(vs['id'])
        break
" 2>/dev/null || true)

if [ -n "${EXISTING_VS_ID}" ]; then
  echo "  Deleting stale vector store ${EXISTING_VS_ID}..."
  _ls_curl "http://localhost:8321/v1/vector_stores/${EXISTING_VS_ID}" -X DELETE >/dev/null
fi

echo "  Creating vector store '${KB_VS_NAME}'..."
VS_ID=$(_ls_curl "http://localhost:8321/v1/vector_stores" \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"name\":\"${KB_VS_NAME}\",\"embedding_model\":\"${KB_EMBEDDING_MODEL}\",\"provider_id\":\"faiss\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)

if [ -z "${VS_ID}" ]; then
  echo "  [WARN] Could not create vector store — RAG knowledge base will not be available"
else
  echo "  [OK] Vector store created: ${VS_ID}"

  LS_POD=$(oc get pod -n rhoai-project \
    -l app.kubernetes.io/instance="${LS_DEPLOY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  DOC_COUNT=0
  DOC_FAIL=0
  for md_file in "${KB_DIR}"/runbooks/*.md "${KB_DIR}"/references/*.md; do
    [ -f "${md_file}" ] || continue
    BASENAME=$(basename "${md_file}")

    oc cp "${md_file}" "rhoai-project/${LS_POD}:/tmp/${BASENAME}" 2>/dev/null

    FILE_ID=$(_ls_curl "http://localhost:8321/v1/files" \
        -F "file=@/tmp/${BASENAME};type=text/plain" -F "purpose=assistants" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

    if [ -n "${FILE_ID}" ]; then
      ATTACH_STATUS=$(_ls_curl "http://localhost:8321/v1/vector_stores/${VS_ID}/files" \
          -X POST -H 'Content-Type: application/json' \
          -d "{\"file_id\":\"${FILE_ID}\"}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
      if [ "${ATTACH_STATUS}" = "completed" ]; then
        ((DOC_COUNT++)) || true
        echo "    [OK] Indexed: ${BASENAME}"
      else
        ((DOC_FAIL++)) || true
        echo "    [FAIL] Index failed: ${BASENAME} (status: ${ATTACH_STATUS})"
      fi
    else
      ((DOC_FAIL++)) || true
      echo "    [FAIL] Upload failed: ${BASENAME}"
    fi
  done

  echo "  [OK] Knowledge base indexed: ${DOC_COUNT} documents (${DOC_FAIL} failures)"

  echo "  Storing vector store ID in ConfigMap..."
  oc create configmap ops-knowledge-base-config -n rhoai-project \
    --from-literal=vector_store_id="${VS_ID}" \
    --from-literal=vector_store_name="${KB_VS_NAME}" \
    --from-literal=embedding_model="${KB_EMBEDDING_MODEL}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "  [OK] Vector store ID saved to ConfigMap ops-knowledge-base-config"
fi
echo ""

echo ""
echo "=== OpenShift AI configuration complete ==="
echo "Mistral Small 3.1 24B INT4 (from Red Hat Model Catalog) + LlamaStack deployed in namespace 'rhoai-project'"
echo "LlamaStack service URL: ${LS_URL}"
echo "RAG sources:"
echo "  - OpenShift Lightspeed (OCP 4.21 product documentation)"
echo "  - Operational Knowledge Base (${DOC_COUNT:-0} documents in LlamaStack vector store)"
echo "Gen AI Playground: enabled (navigate to Gen AI Studio in the OpenShift AI dashboard)"
