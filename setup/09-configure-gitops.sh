#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"
OPERATOR_MANIFESTS="${SCRIPT_DIR}/../manifests/operators"
GITOPS_APP_MANIFESTS="${SCRIPT_DIR}/../demo/gitops/manifests/cnf-sample"
ARGO_APP_MANIFEST="${SCRIPT_DIR}/../demo/gitops/manifests/argocd/application-cnf-sample.yaml"
INCLUSTER_REPO="http://gitea.gitea.svc:3000/gitea_admin/cnf-sample.git"
GITEA_NS="gitea"
GITEA_SECRET="gitea-admin-credentials"
GITOPS_OPERATOR_NS="openshift-gitops-operator"
GITOPS_NS="openshift-gitops"
ARGO_REPO_SECRET="gitea-cnf-sample"

wait_for_namespace() {
  local ns="$1"
  local timeout="${2:-120}"
  echo "  Waiting for namespace '${ns}'..."
  for _ in $(seq 1 $((timeout / 2))); do
    if oc get namespace "${ns}" &>/dev/null; then
      echo "  [OK] Namespace '${ns}' exists"
      return 0
    fi
    sleep 2
  done
  echo "  [FAIL] Namespace '${ns}' not ready within ${timeout}s"
  return 1
}

wait_for_csv() {
  local namespace="$1"
  local name_pattern="$2"
  local timeout="${3:-300}"

  echo "  Waiting for CSV matching '${name_pattern}' in namespace '${namespace}'..."
  for _ in $(seq 1 $((timeout / 5))); do
    CSV_LINE=$(oc get csv -n "${namespace}" --no-headers 2>/dev/null | grep "${name_pattern}" | head -1 || true)
    if [ -n "${CSV_LINE}" ]; then
      PHASE=$(echo "${CSV_LINE}" | awk '{print $NF}')
      if [ "${PHASE}" = "Succeeded" ]; then
        echo "  [OK] CSV ready: $(echo "${CSV_LINE}" | awk '{print $1}')"
        return 0
      fi
    fi
    sleep 5
  done
  echo "  [FAIL] CSV matching '${name_pattern}' not Succeeded within ${timeout}s"
  oc get csv -n "${namespace}" || true
  return 1
}

wait_for_crd() {
  local crd="$1"
  local timeout="${2:-180}"
  echo "  Waiting for CRD '${crd}'..."
  for _ in $(seq 1 $((timeout / 2))); do
    if oc get crd "${crd}" &>/dev/null; then
      echo "  [OK] CRD '${crd}' present"
      return 0
    fi
    sleep 2
  done
  echo "  [FAIL] CRD '${crd}' not present within ${timeout}s"
  return 1
}

# OpenShift GitOps names the server Deployment openshift-gitops-server;
# fall back to argocd-server for upstream-style instances.
wait_for_gitops_server() {
  local timeout="${1:-300}"
  echo "  Waiting for GitOps server Deployment in '${GITOPS_NS}'..."
  for _ in $(seq 1 $((timeout / 5))); do
    for name in openshift-gitops-server argocd-server; do
      if oc get deploy "${name}" -n "${GITOPS_NS}" &>/dev/null; then
        AVAIL=$(oc get deploy "${name}" -n "${GITOPS_NS}" \
          -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        if [ -n "${AVAIL}" ] && [ "${AVAIL}" != "0" ]; then
          echo "  [OK] Deployment '${name}' available (${AVAIL} replica(s))"
          return 0
        fi
      fi
    done
    sleep 5
  done
  echo "  [FAIL] GitOps server Deployment not available within ${timeout}s"
  oc get deploy -n "${GITOPS_NS}" || true
  return 1
}

wait_for_application_controller() {
  local timeout="${1:-300}"
  echo "  Waiting for GitOps application-controller in '${GITOPS_NS}'..."
  for _ in $(seq 1 $((timeout / 5))); do
    READY=$(oc get statefulset -n "${GITOPS_NS}" --no-headers 2>/dev/null \
      | grep -E 'application-controller' | awk '{print $2}' | head -1 || true)
    HAVE="${READY%/*}"
    WANT="${READY#*/}"
    if [ -n "${READY}" ] && [ "${HAVE}" = "${WANT}" ] && [ "${HAVE}" != "0" ]; then
      echo "  [OK] application-controller ready (${READY})"
      return 0
    fi
    sleep 5
  done
  echo "  [WARN] application-controller not ready within ${timeout}s; continuing"
  oc get statefulset -n "${GITOPS_NS}" || true
  return 0
}

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

echo "=== Configuring OpenShift GitOps ==="
echo ""

if ! command -v git &>/dev/null; then
  echo "  ERROR: 'git' CLI is required to seed the cnf-sample repository."
  exit 1
fi

echo "1. Installing OpenShift GitOps Operator..."
oc apply -f "${OPERATOR_MANIFESTS}/gitops-operator-namespace.yaml"
wait_for_namespace "${GITOPS_OPERATOR_NS}" 60
oc apply -f "${OPERATOR_MANIFESTS}/gitops-operator-group.yaml"
oc apply -f "${OPERATOR_MANIFESTS}/gitops-subscription.yaml"
echo ""

echo "2. Waiting for GitOps Operator CSV and Argo CD..."
wait_for_csv "${GITOPS_OPERATOR_NS}" "openshift-gitops-operator" 300
wait_for_crd "applications.argoproj.io" 180
wait_for_namespace "${GITOPS_NS}" 180
wait_for_gitops_server 300
wait_for_application_controller 180
echo ""

echo "3. Reading Gitea route and admin credentials..."
if ! oc get secret "${GITEA_SECRET}" -n "${GITEA_NS}" &>/dev/null; then
  echo "  ERROR: Secret '${GITEA_SECRET}' not found in namespace '${GITEA_NS}'."
  echo "         Run setup/04-deploy-gitea.sh first."
  exit 1
fi

GITEA_USER=$(oc get secret "${GITEA_SECRET}" -n "${GITEA_NS}" -o jsonpath='{.data.username}' | base64 -d)
GITEA_PASS=$(oc get secret "${GITEA_SECRET}" -n "${GITEA_NS}" -o jsonpath='{.data.password}' | base64 -d)
GITEA_ROUTE=$(oc get route gitea -n "${GITEA_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [ -z "${GITEA_USER}" ] || [ -z "${GITEA_PASS}" ]; then
  echo "  ERROR: Could not read Gitea username/password from '${GITEA_SECRET}'."
  exit 1
fi
if [ -z "${GITEA_ROUTE}" ]; then
  echo "  ERROR: Gitea route not found in namespace '${GITEA_NS}'."
  exit 1
fi
echo "  [OK] Gitea route: https://${GITEA_ROUTE}"
echo ""

echo "4. Creating Gitea repository 'cnf-sample' if missing..."
REPO_HTTP=$(curl -sk -o /dev/null -w "%{http_code}" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  "https://${GITEA_ROUTE}/api/v1/repos/${GITEA_USER}/cnf-sample")
if [ "${REPO_HTTP}" = "200" ]; then
  echo "  [OK] Repository cnf-sample already exists"
else
  CREATE_CODE=$(curl -sk -o /tmp/gitea-cnf-sample-create.json -w "%{http_code}" \
    -X POST "https://${GITEA_ROUTE}/api/v1/user/repos" \
    -H "Content-Type: application/json" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -d '{
      "name": "cnf-sample",
      "description": "Sample CNF-like app synced by OpenShift GitOps",
      "private": false,
      "auto_init": true,
      "default_branch": "main",
      "readme": "Default"
    }')
  if [ "${CREATE_CODE}" = "201" ] || [ "${CREATE_CODE}" = "200" ]; then
    echo "  [OK] Repository created"
  else
    echo "  [FAIL] Could not create repository (HTTP ${CREATE_CODE})"
    cat /tmp/gitea-cnf-sample-create.json 2>/dev/null || true
    rm -f /tmp/gitea-cnf-sample-create.json
    exit 1
  fi
  rm -f /tmp/gitea-cnf-sample-create.json
fi
echo ""

echo "5. Seeding cnf-sample repo with known-good manifests..."
if [ ! -d "${GITOPS_APP_MANIFESTS}" ]; then
  echo "  ERROR: Sample app manifests not found at ${GITOPS_APP_MANIFESTS}"
  exit 1
fi

GITEA_PASS_ENC=$(urlencode "${GITEA_PASS}")
REPO_TMP=$(mktemp -d)
if ! git -c http.sslVerify=false clone \
  "https://${GITEA_USER}:${GITEA_PASS_ENC}@${GITEA_ROUTE}/${GITEA_USER}/cnf-sample.git" \
  "${REPO_TMP}" >/dev/null 2>&1; then
  echo "  [FAIL] Could not clone https://${GITEA_ROUTE}/${GITEA_USER}/cnf-sample.git"
  rm -rf "${REPO_TMP}"
  exit 1
fi

cp "${GITOPS_APP_MANIFESTS}/"*.yaml "${REPO_TMP}/"
(
  cd "${REPO_TMP}"
  if git show-ref --verify --quiet refs/remotes/origin/main; then
    git checkout -B main origin/main >/dev/null 2>&1
  else
    # Normalize whatever branch was cloned so repeated runs always seed main.
    git checkout -B main >/dev/null 2>&1
  fi
  git add -A
  if git diff --cached --quiet; then
    echo "  [OK] cnf-sample manifests already up to date"
  else
    git -c user.email="demo@redhat.com" -c user.name="Demo Setup" \
      commit -m "Seed cnf-sample with known-good UBI httpd Deployment" >/dev/null
  fi
  if GIT_SSL_NO_VERIFY=true git push -u origin main >/dev/null 2>&1; then
    echo "  [OK] Manifests available in Gitea (branch main)"
  else
    echo "  [FAIL] git push -u origin main failed"
    exit 1
  fi
)
rm -rf "${REPO_TMP}"
echo ""

echo "6. Registering Gitea repository in Argo CD..."
python3 - "${GITOPS_NS}" "${ARGO_REPO_SECRET}" "${INCLUSTER_REPO}" "${GITEA_USER}" "${GITEA_PASS}" <<'PY' | oc apply -f -
import json, sys
ns, name, url, user, password = sys.argv[1:6]
print(json.dumps({
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": name,
        "namespace": ns,
        "labels": {"argocd.argoproj.io/secret-type": "repository"},
    },
    "type": "Opaque",
    "stringData": {
        "type": "git",
        "url": url,
        "username": user,
        "password": password,
        "insecure": "true",
    },
}))
PY
echo "  [OK] Repository secret '${ARGO_REPO_SECRET}' in ${GITOPS_NS}"
echo ""

echo "7. Applying Argo CD Application 'cnf-sample' (in-cluster repo URL)..."
if [ ! -f "${ARGO_APP_MANIFEST}" ]; then
  echo "  ERROR: Application manifest not found at ${ARGO_APP_MANIFEST}"
  exit 1
fi
sed "s|https://REPLACE_GITEA_HOST/gitea_admin/cnf-sample.git|${INCLUSTER_REPO}|" \
  "${ARGO_APP_MANIFEST}" | oc apply -f -
echo "  [OK] Application applied with repoURL ${INCLUSTER_REPO}"
echo ""

echo "8. Waiting for Application cnf-sample to become Synced/Healthy..."
APP_OK=0
for i in $(seq 1 60); do
  SYNC=$(oc get application cnf-sample -n "${GITOPS_NS}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  HEALTH=$(oc get application cnf-sample -n "${GITOPS_NS}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
  if [ "${SYNC}" = "Synced" ] && [ "${HEALTH}" = "Healthy" ]; then
    echo "  [OK] Application cnf-sample is Synced/Healthy"
    APP_OK=1
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    echo "  Attempt ${i}/60 -- sync=${SYNC:-pending} health=${HEALTH:-pending}"
  fi
  sleep 5
done

if [ "${APP_OK}" -ne 1 ]; then
  echo "  [WARN] Application did not become Synced/Healthy within 300s"
  echo "  Current Application status:"
  oc get application cnf-sample -n "${GITOPS_NS}" -o yaml 2>/dev/null | head -80 || true
  echo "  Destination namespace:"
  oc get deploy,pods -n cnf-gitops-demo 2>/dev/null || true
fi

echo ""
echo "=== OpenShift GitOps configured ==="
echo "Argo CD namespace: ${GITOPS_NS}"
echo "Application: cnf-sample (repo ${INCLUSTER_REPO})"
echo "Destination namespace: cnf-gitops-demo"
echo "Gitea (external): https://${GITEA_ROUTE}/${GITEA_USER}/cnf-sample"
