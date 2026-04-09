#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests/gitea"
CREDS_FILE="${SCRIPT_DIR}/.generated-credentials.env"

# ── Credential helper: generate once, persist, reuse ─────────────────────────
load_or_generate_gitea_password() {
  if [ -f "${CREDS_FILE}" ]; then
    local existing
    existing=$(grep '^GITEA_ADMIN_PASSWORD=' "${CREDS_FILE}" 2>/dev/null | head -1 || true)
    if [ -n "${existing}" ]; then
      GITEA_PASS="${existing#*=}"
      GITEA_PASS="${GITEA_PASS#\'}"; GITEA_PASS="${GITEA_PASS%\'}"
      if [ -n "${GITEA_PASS}" ]; then
        echo "  Reusing Gitea admin password from ${CREDS_FILE}"
        return
      fi
    fi
  fi
  GITEA_PASS="$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)Aa1!"
  echo "GITEA_ADMIN_PASSWORD='${GITEA_PASS}'" >> "${CREDS_FILE}"
  chmod 0600 "${CREDS_FILE}"
  echo "  Generated new Gitea admin password → saved to ${CREDS_FILE}"
}

echo "=== Deploying Gitea Git Server ==="
echo ""

echo "1. Creating namespace and resources..."
oc apply -f "${MANIFESTS_DIR}/namespace.yaml"
oc adm policy add-scc-to-user anyuid -z default -n gitea 2>/dev/null || true
echo "  [OK] anyuid SCC granted to gitea namespace (required for rootless image)"
oc apply -f "${MANIFESTS_DIR}/pvc.yaml"
oc apply -f "${MANIFESTS_DIR}/service.yaml"
oc apply -f "${MANIFESTS_DIR}/route.yaml"
oc apply -f "${MANIFESTS_DIR}/statefulset.yaml"
echo ""

echo "2. Waiting for Gitea pod to be ready..."
for i in $(seq 1 60); do
  READY=$(oc get pods -n gitea -l app=gitea \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "${READY}" = "True" ]; then
    echo "  [OK] Gitea pod is running and ready"
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    POD_STATUS=$(oc get pods -n gitea -l app=gitea --no-headers 2>/dev/null | head -1)
    echo "  Attempt ${i}/60 -- ${POD_STATUS:-waiting...}"
  fi
  sleep 5
done
echo ""

load_or_generate_gitea_password

echo "3. Creating admin user..."
oc exec -n gitea gitea-0 -c gitea -- gitea admin user create \
  --admin \
  --username gitea_admin \
  --password "${GITEA_PASS}" \
  --email admin@example.com \
  --must-change-password=false 2>&1 || echo "  Admin user may already exist"
echo ""

echo "4. Storing admin credentials secret..."
oc create secret generic gitea-admin-credentials \
  -n gitea \
  --from-literal=username=gitea_admin \
  --from-literal=password="${GITEA_PASS}" \
  --dry-run=client -o yaml | oc apply -f -
echo ""

GITEA_ROUTE=$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

echo "5. Creating remediation-playbooks repository..."
curl -sk -X POST "https://${GITEA_ROUTE}/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -u "gitea_admin:${GITEA_PASS}" \
  -d '{
    "name": "remediation-playbooks",
    "description": "AI-generated remediation playbooks for OpenShift self-healing",
    "private": false,
    "auto_init": true,
    "default_branch": "main",
    "readme": "Default"
  }' >/dev/null 2>&1 && echo "  [OK] Repository created" || echo "  Repository may already exist"

echo "6. Pushing workflow playbooks to remediation-playbooks repo..."
REPO_TMP=$(mktemp -d)
git clone "https://gitea_admin:${GITEA_PASS}@${GITEA_ROUTE}/gitea_admin/remediation-playbooks.git" "${REPO_TMP}" 2>/dev/null || true

if [ -d "${REPO_TMP}/.git" ]; then
  ANSIBLE_SRC="${SCRIPT_DIR}/../ansible"

  mkdir -p "${REPO_TMP}/ansible/playbooks"
  mkdir -p "${REPO_TMP}/ansible/roles"
  mkdir -p "${REPO_TMP}/ansible/templates"
  mkdir -p "${REPO_TMP}/ansible/inventory"
  mkdir -p "${REPO_TMP}/ansible/rulebooks"
  mkdir -p "${REPO_TMP}/ansible/execution-environment"

  for pb in check-knowledge-base.yml create-servicenow-incident.yml \
            gather-cluster-diagnostics.yml invoke-ai-known-incident.yml \
            invoke-ai-new-incident.yml store-incident-resolution.yml; do
    [ -f "${ANSIBLE_SRC}/playbooks/${pb}" ] && cp "${ANSIBLE_SRC}/playbooks/${pb}" "${REPO_TMP}/ansible/playbooks/"
  done

  cp -r "${ANSIBLE_SRC}/roles/llamastack_common" "${REPO_TMP}/ansible/roles/" 2>/dev/null || true
  cp -r "${ANSIBLE_SRC}/roles/servicenow_setup" "${REPO_TMP}/ansible/roles/" 2>/dev/null || true
  cp "${ANSIBLE_SRC}/templates/"*.j2 "${REPO_TMP}/ansible/templates/" 2>/dev/null || true
  cp "${ANSIBLE_SRC}/inventory/localhost.yml" "${REPO_TMP}/ansible/inventory/" 2>/dev/null || true
  cp "${ANSIBLE_SRC}/rulebooks/cluster-alert-handler.yml" "${REPO_TMP}/ansible/rulebooks/" 2>/dev/null || true
  # EDA loads rulebooks from extensions/eda/rulebooks/ by convention.
  # Both paths MUST stay in sync; reset-demo.sh re-syncs them on every reset.
  mkdir -p "${REPO_TMP}/extensions/eda/rulebooks"
  cp "${ANSIBLE_SRC}/rulebooks/cluster-alert-handler.yml" "${REPO_TMP}/extensions/eda/rulebooks/" 2>/dev/null || true
  cp "${ANSIBLE_SRC}/ansible.cfg" "${REPO_TMP}/ansible/" 2>/dev/null || true
  cp "${ANSIBLE_SRC}/execution-environment/requirements.yml" "${REPO_TMP}/ansible/execution-environment/" 2>/dev/null || true

  # Push knowledge-base documents (RAG content browsable in Git)
  KB_SRC="${SCRIPT_DIR}/../knowledge-base"
  if [ -d "${KB_SRC}" ]; then
    mkdir -p "${REPO_TMP}/knowledge-base/runbooks"
    mkdir -p "${REPO_TMP}/knowledge-base/references"
    cp "${KB_SRC}"/runbooks/*.md "${REPO_TMP}/knowledge-base/runbooks/" 2>/dev/null || true
    cp "${KB_SRC}"/references/*.md "${REPO_TMP}/knowledge-base/references/" 2>/dev/null || true
  fi

  # AAP runner uses the repo root as CWD; provide a root-level ansible.cfg
  cat > "${REPO_TMP}/ansible.cfg" <<'ROOTCFG'
[defaults]
roles_path = ./ansible/roles
ROOTCFG

  cd "${REPO_TMP}"
  git add -A
  if git diff --cached --quiet; then
    echo "  [OK] Playbooks already up to date"
  else
    git -c user.email="demo@redhat.com" -c user.name="Demo Setup" \
      commit -m "Add self-healing workflow playbooks, roles, and templates" >/dev/null
    git push origin main 2>/dev/null && echo "  [OK] Playbooks pushed to Gitea" || echo "  [WARN] Push failed"
  fi
  cd - >/dev/null
  rm -rf "${REPO_TMP}"
else
  echo "  [WARN] Could not clone repo. Push playbooks manually."
fi

echo ""
echo "=== Gitea deployed ==="
echo "URL: https://${GITEA_ROUTE}"
echo "Username: gitea_admin"
echo "Password: (stored in gitea-admin-credentials secret — run show-credentials.sh to retrieve)"
