#!/bin/bash
###############################################################################
#  reset-demo.sh  --  Reset the Self-Healing Agent demo to a clean state
#
#  This script removes all *demo artifacts* (jobs, generated templates,
#  AI-generated playbooks, ServiceNow incidents, cordoned/NotReady nodes)
#  WITHOUT uninstalling any platform component.
#
#  Safe to run repeatedly before each new demo session.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"
PASS=0
FAIL=0
SKIP=0

ok()   { ((PASS++)) || true; echo "  [OK]   $1"; }
fail() { ((FAIL++)) || true; echo "  [FAIL] $1"; }
skip() { ((SKIP++)) || true; echo "  [SKIP] $1"; }

echo "============================================================"
echo "  OpenShift Self-Healing Agent -- Demo Environment Reset"
echo "============================================================"
echo ""

ok "Logged in as $(oc whoami)"
echo ""

# ── Collect credentials ────────────────────────────────────────────────────

CONTROLLER_HOST="https://$(oc get route aap -n aap -o jsonpath='{.spec.host}' 2>/dev/null || echo "")"
CONTROLLER_PASS=$(oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
GITEA_ROUTE=$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
GITEA_PASS=$(oc get secret gitea-admin-credentials -n gitea -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

SNOW_CREDS="${SCRIPT_DIR}/.servicenow-credentials.env"
SNOW_INSTANCE=""
SNOW_ADMIN_USER=""
SNOW_ADMIN_PASS=""
if [ -f "${SNOW_CREDS}" ]; then
  while IFS= read -r line; do
    [[ "${line}" =~ ^#.*$ ]] && continue
    [[ -z "${line}" ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    value="${value#\'}" ; value="${value%\'}"
    value="${value#\"}" ; value="${value%\"}"
    case "${key}" in
      SNOW_INSTANCE)       SNOW_INSTANCE="${value}" ;;
      SNOW_ADMIN_USERNAME) SNOW_ADMIN_USER="${value}" ;;
      SNOW_ADMIN_PASSWORD) SNOW_ADMIN_PASS="${value}" ;;
    esac
  done < "${SNOW_CREDS}"
fi

###############################################################################
# 1. Restore OpenShift cluster health (all four scenarios)
###############################################################################
echo "1. Restoring OpenShift cluster health..."

echo "   1a. Uncordoning any cordoned worker nodes (UC1)..."
CORDONED=$(oc get nodes --no-headers -o custom-columns='NAME:.metadata.name,SCHED:.spec.unschedulable' 2>/dev/null \
  | grep "true" | awk '{print $1}' || true)
if [ -n "${CORDONED}" ]; then
  for N in ${CORDONED}; do
    oc adm uncordon "${N}" &>/dev/null && ok "Uncordoned node ${N}" || fail "Uncordon ${N}"
  done
else
  skip "No cordoned nodes found"
fi

echo "   1b. Checking for NotReady worker nodes (UC1)..."
NOT_READY=$(oc get nodes -l 'node-role.kubernetes.io/worker' --no-headers \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null \
  | grep -v "True" | awk '{print $1}' || true)
if [ -n "${NOT_READY}" ]; then
  for N in ${NOT_READY}; do
    echo "   Attempting kubelet restart on ${N}..."
    timeout 30 oc debug "node/${N}" --no-tty -- chroot /host systemctl start kubelet &>/dev/null \
      && ok "Kubelet restarted on ${N}" \
      || fail "Could not restart kubelet on ${N} (node may need manual recovery or MachineSet replacement)"
  done
  oc delete pods -n default -l "run" --field-selector=status.phase!=Running --force --grace-period=0 &>/dev/null || true
else
  skip "All worker nodes are Ready"
fi

echo "   1c. Removing broken identity provider if present (UC2)..."
BROKEN_IDP_IDX=$(oc get oauth cluster -o json 2>/dev/null \
  | python3 -c "
import sys, json
idps = json.load(sys.stdin).get('spec', {}).get('identityProviders', [])
for i, idp in enumerate(idps):
    if idp.get('name') == 'broken-htpasswd-demo':
        print(i)
        break
" 2>/dev/null || echo "")
if [ -n "${BROKEN_IDP_IDX}" ]; then
  oc patch oauth cluster --type json \
    -p "[{\"op\":\"remove\",\"path\":\"/spec/identityProviders/${BROKEN_IDP_IDX}\"}]" &>/dev/null \
    && ok "Removed broken IDP 'broken-htpasswd-demo' from OAuth config" \
    || fail "Could not remove broken IDP from OAuth config"
else
  skip "No broken IDP 'broken-htpasswd-demo' found in OAuth config"
fi

echo "   1d. Removing disk-fill files from worker nodes (UC3)..."
WORKERS=$(oc get nodes -l 'node-role.kubernetes.io/worker,!nvidia.com/gpu.present' \
  --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true)
DISK_CLEANED=0
for W in ${WORKERS}; do
  timeout 30 oc debug "node/${W}" --no-tty -- \
    chroot /host rm -f /var/tmp/self-healing-disk-fill &>/dev/null && ((DISK_CLEANED++)) || true
  oc delete pods -n default -l "run" --field-selector=status.phase!=Running --force --grace-period=0 &>/dev/null || true
done
[ "${DISK_CLEANED}" -gt 0 ] \
  && ok "Checked ${DISK_CLEANED} worker node(s) for disk-fill files" \
  || skip "No worker nodes to check for disk-fill files"

echo "   1e. Removing conflicting MachineConfig if present (UC4)..."
if oc get mc self-healing-demo-conflict &>/dev/null; then
  oc delete mc self-healing-demo-conflict &>/dev/null \
    && ok "Deleted MachineConfig self-healing-demo-conflict" \
    || fail "Could not delete MachineConfig self-healing-demo-conflict"
else
  skip "No conflicting MachineConfig found"
fi
echo ""

###############################################################################
# 2. Clean AAP: workflow jobs, remediation job templates, job history
###############################################################################
echo "2. Cleaning Red Hat Ansible Automation Platform..."

if [ -n "${CONTROLLER_PASS}" ] && [ "${CONTROLLER_HOST}" != "https://" ]; then

  echo "   2a. Deleting 'Remediate *' Job Templates..."
  REMEDIATE_JTS=$(curl -sk -u "admin:${CONTROLLER_PASS}" \
    "${CONTROLLER_HOST}/api/controller/v2/job_templates/?name__startswith=Remediate&page_size=100" \
    -H 'Accept: application/json' 2>/dev/null \
    | python3 -c "
import sys, json
for r in json.load(sys.stdin).get('results', []):
    print(f'{r[\"id\"]}|{r[\"name\"]}')
" 2>/dev/null || true)
  if [ -n "${REMEDIATE_JTS}" ]; then
    while IFS='|' read -r jt_id jt_name; do
      [ -z "${jt_id}" ] && continue
      HTTP=$(curl -sk -u "admin:${CONTROLLER_PASS}" \
        "${CONTROLLER_HOST}/api/controller/v2/job_templates/${jt_id}/" \
        -X DELETE -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
      [ "${HTTP}" -ge 200 ] && [ "${HTTP}" -lt 300 ] \
        && ok "Deleted JT: ${jt_name}" \
        || fail "Delete JT ${jt_name} (HTTP ${HTTP})"
    done <<< "${REMEDIATE_JTS}"
  else
    skip "No Remediate Job Templates found"
  fi

  echo "   2b. Purging all job history (workflow jobs, jobs, project updates)..."
  echo "        This may take a few minutes for large histories..."
  JOB_RESULT=$(python3 - "${CONTROLLER_HOST}" "${CONTROLLER_PASS}" << 'PYEOF'
import urllib.request, urllib.error, json, base64, ssl, sys

host, password = sys.argv[1], sys.argv[2]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
auth = base64.b64encode(f"admin:{password}".encode()).decode()
headers = {"Accept": "application/json", "Authorization": f"Basic {auth}"}

endpoints = [
    ("workflow_jobs",   "/api/controller/v2/workflow_jobs/"),
    ("jobs",            "/api/controller/v2/jobs/"),
    ("project_updates", "/api/controller/v2/project_updates/"),
]
totals = {}

for label, ep in endpoints:
    deleted = 0
    while True:
        url = f"{host}{ep}?page=1&page_size=200&order_by=id"
        req = urllib.request.Request(url, headers=headers)
        try:
            resp = urllib.request.urlopen(req, context=ctx)
            data = json.loads(resp.read())
        except Exception:
            break
        results = data.get("results", [])
        if not results:
            break
        for r in results:
            del_url = f"{host}{ep}{r['id']}/"
            del_req = urllib.request.Request(del_url, headers=headers, method="DELETE")
            try:
                urllib.request.urlopen(del_req, context=ctx)
            except Exception:
                pass
            deleted += 1
    totals[label] = deleted

parts = []
for label, count in totals.items():
    if count > 0:
        parts.append(f"{count} {label.replace('_', ' ')}")
print("|".join(parts) if parts else "NONE")
PYEOF
  )
  if [ "${JOB_RESULT}" = "NONE" ]; then
    skip "No job history to delete"
  else
    IFS='|' read -ra PARTS <<< "${JOB_RESULT}"
    for PART in "${PARTS[@]}"; do
      ok "Deleted ${PART}"
    done
  fi

  echo "   2d. Restarting EDA rulebook activation (reset throttle state)..."
  RBA_INFO=$(curl -sk -u "admin:${CONTROLLER_PASS}" \
    "${CONTROLLER_HOST}/api/eda/v1/activations/?name=Cluster+Alert+Handler" \
    -H 'Accept: application/json' 2>/dev/null \
    | python3 -c "
import sys, json
results = json.load(sys.stdin).get('results', [])
if results:
    print(f'{results[0][\"id\"]}|{results[0].get(\"is_enabled\",True)}')
" 2>/dev/null || true)
  if [ -n "${RBA_INFO}" ]; then
    RBA_ID="${RBA_INFO%%|*}"
    curl -sk -u "admin:${CONTROLLER_PASS}" \
      "${CONTROLLER_HOST}/api/eda/v1/activations/${RBA_ID}/disable/" \
      -X POST -H 'Content-Type: application/json' -o /dev/null 2>/dev/null || true
    echo "        Waiting for EDA activation to fully stop..."
    for i in $(seq 1 12); do
      sleep 5
      RBA_STATUS=$(curl -sk -u "admin:${CONTROLLER_PASS}" \
        "${CONTROLLER_HOST}/api/eda/v1/activations/${RBA_ID}/" \
        -H 'Accept: application/json' 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
      [ "${RBA_STATUS}" = "completed" ] || [ "${RBA_STATUS}" = "stopped" ] && break
    done
    curl -sk -u "admin:${CONTROLLER_PASS}" \
      "${CONTROLLER_HOST}/api/eda/v1/activations/${RBA_ID}/enable/" \
      -X POST -H 'Content-Type: application/json' -o /dev/null 2>/dev/null || true
    echo "        Waiting for EDA activation to become running..."
    EDA_OK=false
    for i in $(seq 1 12); do
      sleep 5
      RBA_STATUS=$(curl -sk -u "admin:${CONTROLLER_PASS}" \
        "${CONTROLLER_HOST}/api/eda/v1/activations/${RBA_ID}/" \
        -H 'Accept: application/json' 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
      if [ "${RBA_STATUS}" = "running" ]; then
        EDA_OK=true
        break
      fi
    done
    if ${EDA_OK}; then
      ok "EDA activation restarted and running (throttle state cleared)"
    else
      fail "EDA activation did not reach running state (status: ${RBA_STATUS}). Re-enable it manually in the AAP UI."
    fi
  else
    skip "EDA rulebook activation not found"
  fi

  echo "   2e. Syncing AAP project to latest Git state..."
  PROJECT_ID=$(curl -sk -u "admin:${CONTROLLER_PASS}" \
    "${CONTROLLER_HOST}/api/controller/v2/projects/?name=Self-Healing+Agent" \
    -H 'Accept: application/json' 2>/dev/null \
    | python3 -c "import sys, json; r=json.load(sys.stdin).get('results',[]); print(r[0]['id'] if r else '')" 2>/dev/null || true)
  if [ -n "${PROJECT_ID}" ]; then
    curl -sk -u "admin:${CONTROLLER_PASS}" \
      "${CONTROLLER_HOST}/api/controller/v2/projects/${PROJECT_ID}/update/" \
      -X POST -H 'Content-Type: application/json' -o /dev/null 2>/dev/null || true
    ok "Project sync triggered"
  else
    skip "Self-Healing Agent project not found"
  fi

else
  skip "AAP not reachable -- skipping AAP cleanup"
fi
echo ""

###############################################################################
# 3. Clean Gitea: AI-generated playbooks in playbooks/ directory
###############################################################################
echo "3. Cleaning Gitea AI-generated playbooks..."

if [ -n "${GITEA_ROUTE}" ] && [ -n "${GITEA_PASS}" ]; then
  GENERATED_FILES=$(curl -sk -u "gitea_admin:${GITEA_PASS}" \
    "https://${GITEA_ROUTE}/api/v1/repos/gitea_admin/remediation-playbooks/contents/playbooks" \
    -H 'Accept: application/json' 2>/dev/null \
    | python3 -c "
import sys, json
for f in json.load(sys.stdin):
    name = f.get('name', '')
    if name.startswith('remediate-'):
        print(f'{name}|{f[\"sha\"]}')
" 2>/dev/null || true)
  if [ -n "${GENERATED_FILES}" ]; then
    while IFS='|' read -r fname fsha; do
      [ -z "${fname}" ] && continue
      HTTP=$(curl -sk -u "gitea_admin:${GITEA_PASS}" \
        "https://${GITEA_ROUTE}/api/v1/repos/gitea_admin/remediation-playbooks/contents/playbooks/${fname}" \
        -X DELETE -H 'Content-Type: application/json' \
        -d "{\"message\":\"Demo reset: remove generated playbook\",\"sha\":\"${fsha}\"}" \
        -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
      [ "${HTTP}" -ge 200 ] && [ "${HTTP}" -lt 300 ] \
        && ok "Deleted playbooks/${fname}" \
        || fail "Delete playbooks/${fname} (HTTP ${HTTP})"
    done <<< "${GENERATED_FILES}"
  else
    skip "No AI-generated playbooks found in Gitea"
  fi
  echo "   3b. Syncing EDA rulebook to Gitea (prevents stale-rulebook issues)..."
  LOCAL_RULEBOOK="${SCRIPT_DIR}/../ansible/rulebooks/cluster-alert-handler.yml"
  if [ -f "${LOCAL_RULEBOOK}" ]; then
    CONTENT_B64=$(base64 -w0 < "${LOCAL_RULEBOOK}")
    for GITEA_PATH in "extensions/eda/rulebooks/cluster-alert-handler.yml" "ansible/rulebooks/cluster-alert-handler.yml"; do
      FILE_SHA=$(curl -sk -u "gitea_admin:${GITEA_PASS}" \
        "https://${GITEA_ROUTE}/api/v1/repos/gitea_admin/remediation-playbooks/contents/${GITEA_PATH}" \
        -H 'Accept: application/json' 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")
      if [ -n "${FILE_SHA}" ]; then
        HTTP=$(curl -sk -u "gitea_admin:${GITEA_PASS}" \
          "https://${GITEA_ROUTE}/api/v1/repos/gitea_admin/remediation-playbooks/contents/${GITEA_PATH}" \
          -X PUT -H 'Content-Type: application/json' \
          -d "{\"message\":\"Demo reset: sync EDA rulebook\",\"content\":\"${CONTENT_B64}\",\"sha\":\"${FILE_SHA}\"}" \
          -o /dev/null -w '%{http_code}' 2>/dev/null || echo "000")
        [ "${HTTP}" -ge 200 ] && [ "${HTTP}" -lt 300 ] \
          && ok "Synced ${GITEA_PATH}" \
          || fail "Sync ${GITEA_PATH} (HTTP ${HTTP})"
      else
        skip "${GITEA_PATH} not found in Gitea"
      fi
    done
  else
    skip "Local rulebook not found"
  fi

else
  skip "Gitea not reachable -- skipping Gitea cleanup"
fi
echo ""

###############################################################################
# 4. Clean ServiceNow: delete all incidents
###############################################################################
echo "4. Cleaning ServiceNow incidents..."

if [ -n "${SNOW_INSTANCE}" ] && [ -n "${SNOW_ADMIN_PASS}" ]; then
  INC_LIST=$(curl -sk -u "${SNOW_ADMIN_USER}:${SNOW_ADMIN_PASS}" \
    "${SNOW_INSTANCE}/api/now/table/incident?sysparm_fields=sys_id,number&sysparm_limit=500" \
    -H 'Accept: application/json' 2>/dev/null \
    | python3 -c "
import sys, json
for i in json.load(sys.stdin).get('result', []):
    print(f'{i[\"sys_id\"]}|{i[\"number\"]}')
" 2>/dev/null || true)
  if [ -n "${INC_LIST}" ]; then
    INC_COUNT=0
    while IFS='|' read -r sid num; do
      [ -z "${sid}" ] && continue
      curl -sk -u "${SNOW_ADMIN_USER}:${SNOW_ADMIN_PASS}" \
        "${SNOW_INSTANCE}/api/now/table/incident/${sid}" \
        -X DELETE -H 'Accept: application/json' -o /dev/null 2>/dev/null || true
      ((INC_COUNT++)) || true
    done <<< "${INC_LIST}"
    ok "Deleted ${INC_COUNT} ServiceNow incident(s)"
  else
    skip "No incidents found in ServiceNow"
  fi
else
  skip "ServiceNow credentials not found -- skipping SNOW cleanup"
fi
echo ""

###############################################################################
# 5. Re-apply Alertmanager config (ensures webhook is current)
###############################################################################
echo "5. Re-applying Alertmanager configuration..."

ALERTMANAGER_MANIFEST="${SCRIPT_DIR}/../manifests/monitoring/alertmanager-config.yaml"
if [ -f "${ALERTMANAGER_MANIFEST}" ]; then
  oc apply -f "${ALERTMANAGER_MANIFEST}" &>/dev/null \
    && ok "Alertmanager config re-applied" \
    || fail "Alertmanager config apply"
else
  skip "Alertmanager manifest not found"
fi
echo ""

###############################################################################
# 6. Re-label protected nodes
###############################################################################
echo "6. Re-labelling protected nodes..."

PROTECTED_NAMESPACES="aap rhoai-project self-healing-agent gitea"
LABELED=0
for NS in ${PROTECTED_NAMESPACES}; do
  NODES=$(oc get pods -n "${NS}" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u || true)
  for N in ${NODES}; do
    [ -z "${N}" ] && continue
    CURRENT=$(oc get node "${N}" -o jsonpath='{.metadata.labels.self-healing-agent\.demo/protected}' 2>/dev/null || true)
    if [ "${CURRENT}" != "true" ]; then
      oc label node "${N}" self-healing-agent.demo/protected=true --overwrite &>/dev/null || true
      ((LABELED++)) || true
    fi
  done
done
[ "${LABELED}" -gt 0 ] \
  && ok "Labelled ${LABELED} node(s) as protected" \
  || skip "Protected labels already up to date"
echo ""

###############################################################################
# Summary
###############################################################################
echo "============================================================"
echo "  Reset complete:  ${PASS} passed  |  ${FAIL} failed  |  ${SKIP} skipped"
echo "============================================================"
echo ""
if [ "${FAIL}" -gt 0 ]; then
  echo "  Some steps failed. Review the output above and fix manually if needed."
  echo ""
fi
echo "  The demo environment is ready for a fresh run."
echo ""
echo "  Trigger a scenario:"
echo "    UC1  ./demo/scenarios/01-worker-node-failure/trigger.sh"
echo "    UC2  ./demo/scenarios/02-authentication-operator-degraded/trigger.sh"
echo "    UC3  ./demo/scenarios/03-node-disk-pressure/trigger.sh"
echo "    UC4  ./demo/scenarios/04-mcp-degraded/trigger.sh"
echo ""
echo "  Show credentials:  ./setup/show-credentials.sh"
echo ""
