#!/bin/bash
# Health check for the Self-Healing Agent demo environment.
# Run after the cluster starts up to verify every component is operational.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

PASS=0
WARN=0
FAIL=0

pass() { echo "  [PASS] $1"; ((PASS++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

section() { echo ""; echo "── $1 ──"; }

# ─────────────────────────────────────────────
section "1. OpenShift Cluster"
# ─────────────────────────────────────────────

pass "Authenticated as $(oc whoami)"

API_STATUS=$(oc get --raw /healthz 2>/dev/null || echo "error")
if [ "${API_STATUS}" = "ok" ]; then
  pass "API server healthy"
else
  fail "API server returned: ${API_STATUS}"
fi

TOTAL_NODES=$(oc get nodes --no-headers 2>/dev/null | wc -l)
READY_NODES=$(oc get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
NOT_READY=$(oc get nodes --no-headers 2>/dev/null | grep -v " Ready" || true)
if [ "${READY_NODES}" -eq "${TOTAL_NODES}" ]; then
  pass "All ${TOTAL_NODES} nodes Ready"
else
  warn "${READY_NODES}/${TOTAL_NODES} nodes Ready"
  echo "${NOT_READY}" | while read -r line; do
    NODE_NAME=$(echo "${line}" | awk '{print $1}')
    NODE_STATUS=$(echo "${line}" | awk '{print $2}')
    echo "        ${NODE_NAME}  ${NODE_STATUS}"
  done
fi

# ─────────────────────────────────────────────
section "2. Operators (CSV status)"
# ─────────────────────────────────────────────

check_csv() {
  local ns="$1" pattern="$2" label="$3"
  CSV_LINE=$(oc get csv -n "${ns}" --no-headers 2>/dev/null | grep "${pattern}" | head -1)
  if [ -z "${CSV_LINE}" ]; then
    fail "${label}: CSV not found in ${ns}"
  else
    PHASE=$(echo "${CSV_LINE}" | awk '{print $NF}')
    CSV_NAME=$(echo "${CSV_LINE}" | awk '{print $1}')
    if [ "${PHASE}" = "Succeeded" ]; then
      pass "${label}: ${CSV_NAME}"
    else
      fail "${label}: ${CSV_NAME} (${PHASE})"
    fi
  fi
}

check_csv "aap"                      "aap-operator"         "AAP Operator"
check_csv "redhat-ods-operator"      "rhods-operator"       "OpenShift AI Operator"
check_csv "openshift-lightspeed"     "lightspeed-operator"  "Lightspeed Operator"
check_csv "openshift-nfd"            "nfd"                  "NFD Operator"
check_csv "nvidia-gpu-operator"      "gpu-operator"         "GPU Operator"

# ─────────────────────────────────────────────
section "3. Red Hat Ansible Automation Platform"
# ─────────────────────────────────────────────

check_deploy() {
  local ns="$1" name="$2" label="$3"
  READY=$(oc get deploy "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(oc get deploy "${name}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [ "${READY}" = "${DESIRED}" ] && [ "${READY}" != "0" ]; then
    pass "${label} (${READY}/${DESIRED} replicas)"
  else
    fail "${label} (${READY:-0}/${DESIRED:-?} replicas)"
  fi
}

CTRL_ROUTE=$(oc get route aap-controller -n aap -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
CTRL_PASS=$(oc get secret aap-controller-admin-password -n aap -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -n "${CTRL_ROUTE}" ] && [ -n "${CTRL_PASS}" ]; then
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' -u "admin:${CTRL_PASS}" \
    "https://${CTRL_ROUTE}/api/controller/v2/ping/" 2>/dev/null || echo "000")
  if [ "${HTTP_CODE}" = "200" ]; then
    pass "AAP Controller API reachable (${CTRL_ROUTE})"
  else
    fail "AAP Controller API returned HTTP ${HTTP_CODE}"
  fi
else
  fail "AAP Controller route or password not found"
fi

AAP_GW_HOST=$(oc get route aap -n aap -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
AAP_GW_PASS=$(oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -n "${AAP_GW_HOST}" ] && [ -n "${AAP_GW_PASS}" ]; then
  EDA_STATUS=$(curl -sk -u "admin:${AAP_GW_PASS}" \
    "https://${AAP_GW_HOST}/api/eda/v1/activations/" 2>/dev/null)
  ACT_INFO=$(echo "${EDA_STATUS}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('results', []):
    print(f'{a.get(\"id\",\"\")},{a.get(\"status\",\"?\")},{a.get(\"is_enabled\",\"?\")},{a.get(\"restart_count\",0)}')
" 2>/dev/null | head -1)
  ACT_ID=$(echo "${ACT_INFO}" | cut -d',' -f1)
  ACT_ST=$(echo "${ACT_INFO}" | cut -d',' -f2)
  ACT_EN=$(echo "${ACT_INFO}" | cut -d',' -f3)
  ACT_RC=$(echo "${ACT_INFO}" | cut -d',' -f4)

  if [ "${ACT_ST}" = "running" ] && [ "${ACT_EN}" = "True" ]; then
    pass "EDA activation running and enabled"
  elif [ "${ACT_ST}" = "running" ]; then
    pass "EDA activation running (enabled=${ACT_EN})"
  elif [ -n "${ACT_ID}" ] && { [ "${ACT_ST}" = "failed" ] || [ "${ACT_ST}" = "stopped" ] || [ "${ACT_ST}" = "error" ]; }; then
    warn "EDA activation status: ${ACT_ST} (restart_count=${ACT_RC}) — attempting restart..."
    RESTART_CODE=$(curl -sk -u "admin:${AAP_GW_PASS}" -X POST \
      "https://${AAP_GW_HOST}/api/eda/v1/activations/${ACT_ID}/restart/" \
      -H "Content-Type: application/json" -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
    if [ "${RESTART_CODE}" = "204" ] || [ "${RESTART_CODE}" = "200" ]; then
      echo "        Restart requested (HTTP ${RESTART_CODE}). Waiting for activation to start..."
      ACTIVATION_UP=false
      for i in $(seq 1 12); do
        sleep 5
        NEW_ST=$(curl -sk -u "admin:${AAP_GW_PASS}" \
          "https://${AAP_GW_HOST}/api/eda/v1/activations/${ACT_ID}/" 2>/dev/null \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
        if [ "${NEW_ST}" = "running" ]; then
          ACTIVATION_UP=true
          break
        fi
        echo "        ... status: ${NEW_ST:-pending} (${i}/12)"
      done
      if [ "${ACTIVATION_UP}" = true ]; then
        pass "EDA activation recovered — now running"
      else
        fail "EDA activation restart requested but did not reach running state within 60s"
      fi
    else
      fail "EDA activation ${ACT_ST} — restart failed (HTTP ${RESTART_CODE})"
    fi
  elif [ -n "${ACT_ST}" ]; then
    warn "EDA activation status: ${ACT_ST}, enabled: ${ACT_EN}"
  else
    fail "EDA activations endpoint unreachable"
  fi
else
  fail "AAP gateway route or password not found"
fi

# Check webhook service exists (created by a running activation)
WEBHOOK_SVC=$(oc get svc cluster-alert-handler -n aap -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [ -n "${WEBHOOK_SVC}" ]; then
  pass "EDA webhook service exists (${WEBHOOK_SVC}:5000)"
else
  fail "EDA webhook service 'cluster-alert-handler' not found — alerts cannot reach EDA"
fi

# ─────────────────────────────────────────────
section "4. Red Hat OpenShift AI"
# ─────────────────────────────────────────────

DSC_PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${DSC_PHASE}" = "Ready" ]; then
  pass "DataScienceCluster: Ready"
else
  fail "DataScienceCluster: ${DSC_PHASE:-not found}"
fi

IS_READY=$(oc get inferenceservice mistral-small-3-1-24b -n rhoai-project \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [ "${IS_READY}" = "True" ]; then
  pass "InferenceService mistral-small-3-1-24b: Ready"
else
  fail "InferenceService mistral-small-3-1-24b: ${IS_READY:-not found}"
fi

LS_PHASE=$(oc get llamastackdistribution self-healing-agent -n rhoai-project \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${LS_PHASE}" = "Ready" ]; then
  pass "LlamaStack distribution: Ready"
else
  fail "LlamaStack distribution: ${LS_PHASE:-not found}"
fi

LS_SVC=$(oc get svc self-healing-agent-service -n rhoai-project \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [ -n "${LS_SVC}" ]; then
  pass "LlamaStack service reachable (${LS_SVC}:8321)"
else
  fail "LlamaStack service not found"
fi

# ─────────────────────────────────────────────
section "5. OpenShift Lightspeed"
# ─────────────────────────────────────────────

OLS_OVERALL=$(oc get olsconfig cluster -o jsonpath='{.status.overallStatus}' 2>/dev/null || echo "")
if [ "${OLS_OVERALL}" = "Ready" ]; then
  pass "OLSConfig: Ready"
else
  fail "OLSConfig: ${OLS_OVERALL:-not found}"
fi

OLS_READY=$(oc exec -n openshift-lightspeed deploy/lightspeed-app-server \
  -c lightspeed-service-api -- curl -sk https://localhost:8443/readiness 2>/dev/null || echo "{}")
if echo "${OLS_READY}" | python3 -c "import sys,json; assert json.load(sys.stdin).get('ready')==True" 2>/dev/null; then
  pass "Lightspeed API: healthy"
else
  fail "Lightspeed API readiness: ${OLS_READY}"
fi

OLS_TOKEN=$(oc get secret self-healing-ols-token -n openshift-lightspeed \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ -n "${OLS_TOKEN}" ]; then
  pass "Self-healing OLS token secret present (${#OLS_TOKEN} chars)"
else
  fail "OLS token secret 'self-healing-ols-token' missing or empty"
fi

OLS_NP=$(oc get networkpolicy allow-aap-to-lightspeed -n openshift-lightspeed \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
if [ -n "${OLS_NP}" ]; then
  pass "NetworkPolicy allow-aap-to-lightspeed exists"
else
  warn "NetworkPolicy allow-aap-to-lightspeed missing -- AAP cannot reach Lightspeed"
fi

# ─────────────────────────────────────────────
section "6. Gitea"
# ─────────────────────────────────────────────

GITEA_ROUTE=$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
GITEA_PASS=$(oc get secret gitea-admin-credentials -n gitea -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -n "${GITEA_ROUTE}" ]; then
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${GITEA_ROUTE}/" 2>/dev/null || echo "000")
  if [ "${HTTP_CODE}" = "200" ]; then
    pass "Gitea web UI reachable (${GITEA_ROUTE})"
  else
    fail "Gitea returned HTTP ${HTTP_CODE}"
  fi
else
  fail "Gitea route not found"
fi

if [ -n "${GITEA_ROUTE}" ] && [ -n "${GITEA_PASS}" ]; then
  REPO_CHECK=$(curl -sk -u "gitea_admin:${GITEA_PASS}" \
    "https://${GITEA_ROUTE}/api/v1/repos/gitea_admin/remediation-playbooks" \
    -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
  if [ "${REPO_CHECK}" = "200" ]; then
    pass "Gitea repo 'remediation-playbooks' accessible"
  else
    fail "Gitea repo returned HTTP ${REPO_CHECK}"
  fi
fi

# ─────────────────────────────────────────────
section "7. ServiceNow"
# ─────────────────────────────────────────────

SNOW_CREDS="${SCRIPT_DIR}/.servicenow-credentials.env"
if [ -f "${SNOW_CREDS}" ]; then
  # Safe parsing of credentials file (handles special chars in passwords)
  SNOW_URL=""
  SNOW_USER=""
  SNOW_PASS=""
  while IFS= read -r line; do
    [[ "${line}" =~ ^#.*$ ]] && continue
    [[ -z "${line}" ]] && continue
    KEY="${line%%=*}"
    VAL="${line#*=}"
    case "${KEY}" in
      SNOW_INSTANCE)       SNOW_URL="${VAL}" ;;
      SNOW_ADMIN_USERNAME) SNOW_USER="${VAL}" ;;
      SNOW_ADMIN_PASSWORD) SNOW_PASS="${VAL}" ;;
    esac
  done < "${SNOW_CREDS}"

  if [ -n "${SNOW_URL}" ]; then
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
      -u "${SNOW_USER}:${SNOW_PASS}" \
      "${SNOW_URL}/api/now/table/sys_properties?sysparm_limit=1" \
      -H 'Accept: application/json' 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" = "200" ]; then
      pass "ServiceNow instance reachable and authenticated (${SNOW_URL})"
    elif [ "${HTTP_CODE}" = "401" ] || [ "${HTTP_CODE}" = "403" ]; then
      warn "ServiceNow reachable but auth failed (HTTP ${HTTP_CODE}) -- password may have changed"
    elif [ "${HTTP_CODE}" = "000" ]; then
      warn "ServiceNow unreachable -- dev instance may be hibernating (wake it at ${SNOW_URL})"
    else
      warn "ServiceNow returned HTTP ${HTTP_CODE}"
    fi
  fi
else
  warn "ServiceNow credentials file not found (${SNOW_CREDS})"
fi

# ─────────────────────────────────────────────
section "8. Monitoring & Alerting"
# ─────────────────────────────────────────────

PR_COUNT=$(oc get prometheusrule -n openshift-monitoring --no-headers 2>/dev/null | grep -c "self-healing" || true)
if [ "${PR_COUNT}" -gt 0 ]; then
  pass "PrometheusRule(s) for self-healing present (${PR_COUNT})"
else
  warn "No self-healing PrometheusRules found in openshift-monitoring"
fi

AM_SECRET=$(oc get secret alertmanager-main -n openshift-monitoring \
  -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if echo "${AM_SECRET}" | grep -q "eda-webhook" 2>/dev/null; then
  pass "Alertmanager config contains eda-webhook receiver"
else
  fail "Alertmanager config missing eda-webhook receiver"
fi

# ─────────────────────────────────────────────
section "9. NetworkPolicies"
# ─────────────────────────────────────────────

NP_LLAMA=$(oc get networkpolicy allow-aap-to-llamastack -n rhoai-project \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
if [ -n "${NP_LLAMA}" ]; then
  pass "NetworkPolicy allow-aap-to-llamastack (rhoai-project)"
else
  warn "NetworkPolicy allow-aap-to-llamastack missing"
fi

NP_OLS=$(oc get networkpolicy allow-aap-to-lightspeed -n openshift-lightspeed \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
if [ -n "${NP_OLS}" ]; then
  pass "NetworkPolicy allow-aap-to-lightspeed (openshift-lightspeed)"
else
  warn "NetworkPolicy allow-aap-to-lightspeed missing"
fi

# ─────────────────────────────────────────────
section "10. End-to-End Connectivity (from AAP namespace)"
# ─────────────────────────────────────────────

AAP_POD=$(oc get pods -n aap --no-headers 2>/dev/null | grep "Running" | head -1 | awk '{print $1}')
if [ -n "${AAP_POD}" ]; then
  # LlamaStack
  LS_CHECK=$(oc exec -n aap "${AAP_POD}" -- \
    curl -sk --max-time 5 http://self-healing-agent-service.rhoai-project.svc.cluster.local:8321/v1/models \
    -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
  if [ "${LS_CHECK}" = "200" ]; then
    pass "AAP → LlamaStack connectivity OK"
  else
    fail "AAP → LlamaStack returned HTTP ${LS_CHECK}"
  fi

  # Lightspeed
  OLS_CHECK=$(oc exec -n aap "${AAP_POD}" -- \
    curl -sk --max-time 5 https://lightspeed-app-server.openshift-lightspeed.svc:8443/readiness \
    -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
  if [ "${OLS_CHECK}" = "200" ]; then
    pass "AAP → Lightspeed connectivity OK"
  else
    fail "AAP → Lightspeed returned HTTP ${OLS_CHECK}"
  fi

  # Gitea (internal)
  GITEA_SVC_CHECK=$(oc exec -n aap "${AAP_POD}" -- \
    curl -sk --max-time 5 "https://gitea-gitea.apps.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)/" \
    -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
  if [ "${GITEA_SVC_CHECK}" = "200" ]; then
    pass "AAP → Gitea connectivity OK"
  else
    warn "AAP → Gitea returned HTTP ${GITEA_SVC_CHECK}"
  fi
else
  warn "No running pod in aap namespace to test connectivity"
fi

# ─────────────────────────────────────────────
section "Summary"
# ─────────────────────────────────────────────

TOTAL=$((PASS + WARN + FAIL))
echo ""
echo "  PASS: ${PASS}  |  WARN: ${WARN}  |  FAIL: ${FAIL}  |  TOTAL: ${TOTAL}"
echo ""

if [ "${FAIL}" -eq 0 ] && [ "${WARN}" -eq 0 ]; then
  echo "  All checks passed. The demo environment is ready."
elif [ "${FAIL}" -eq 0 ]; then
  echo "  No failures, but ${WARN} warning(s) to review."
  echo "  The demo environment is likely usable -- check the warnings above."
else
  echo "  ${FAIL} check(s) FAILED. Review the output above before running the demo."
  echo "  Common fixes after cluster restart:"
  echo "    - Pods not ready: wait a few minutes for rollouts to complete"
  echo "    - InferenceService not ready: GPU node may still be initializing"
  echo "    - ServiceNow unreachable: wake the dev instance at its URL"
  echo "    - EDA activation stopped: re-enable via AAP EDA UI or reset-demo.sh"
fi
echo ""

exit "${FAIL}"
