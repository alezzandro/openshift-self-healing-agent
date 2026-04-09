#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "=== Configuring Ansible Automation Platform ==="
echo ""

echo "1. Creating AAP instance..."
oc apply -f "${SCRIPT_DIR}/../manifests/operators/aap-instance.yaml"
echo ""

echo "2. Waiting for AAP components to start deploying..."
for i in $(seq 1 120); do
  RUNNING=$(oc get aap aap -n aap -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || echo "")
  if [ "${RUNNING}" = "True" ]; then
    echo "  [OK] AAP is running reconciliation"
    break
  fi
  if [ "$((i % 4))" -eq 0 ]; then
    echo "  Attempt ${i}/120 -- waiting for AAP deployment..."
  fi
  sleep 15
done
echo ""

echo "3. Configuring Hub for RWO storage and single-zone scheduling..."

oc patch automationhub aap-hub -n aap --type merge -p '{
  "spec": {
    "file_storage_access_mode": "ReadWriteOnce",
    "file_storage_size": "10Gi",
    "content": {"replicas": 1},
    "worker": {"replicas": 1}
  }
}' 2>/dev/null && echo "  [OK] Hub CR patched (RWO, single replicas)" || echo "  [WARN] Hub CR patch skipped"

HUB_PVC_STATUS=$(oc get pvc aap-hub-file-storage -n aap -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${HUB_PVC_STATUS}" = "Pending" ]; then
  echo "  Hub PVC is Pending (likely RWX on EBS). Recreating with RWO..."
  oc delete pvc aap-hub-file-storage -n aap 2>/dev/null || true
  cat <<'PVCEOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: aap-hub-file-storage
  namespace: aap
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3-csi
PVCEOF
  echo "  [OK] Hub PVC recreated with ReadWriteOnce"
elif [ -z "${HUB_PVC_STATUS}" ]; then
  echo "  Hub PVC not found yet. Creating with RWO..."
  cat <<'PVCEOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: aap-hub-file-storage
  namespace: aap
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3-csi
PVCEOF
  echo "  [OK] Hub PVC created with ReadWriteOnce"
else
  echo "  [OK] Hub PVC already ${HUB_PVC_STATUS}"
fi

HUB_ZONE=""
PV_NAME=$(oc get pvc aap-hub-file-storage -n aap -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
if [ -n "${PV_NAME}" ]; then
  HUB_ZONE=$(oc get pv "${PV_NAME}" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[?(@.key=="topology.kubernetes.io/zone")].values[0]}' 2>/dev/null || echo "")
fi
if [ -z "${HUB_ZONE}" ]; then
  HUB_ZONE=$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/worker-gpu' \
    -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "")
fi

if [ -n "${HUB_ZONE}" ]; then
  echo "  Pinning Hub pods to zone: ${HUB_ZONE}"
  oc patch automationhub aap-hub -n aap --type merge \
    -p "{\"spec\":{\"node_selector\":\"topology.kubernetes.io/zone: ${HUB_ZONE}\"}}" 2>/dev/null || true

  for DEP in aap-hub-api aap-hub-content aap-hub-web aap-hub-worker; do
    oc patch deployment "${DEP}" -n aap --type strategic \
      -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"topology.kubernetes.io/zone\":\"${HUB_ZONE}\"}}}}}" 2>/dev/null || true
  done
  echo "  [OK] Hub deployments pinned to zone ${HUB_ZONE}"

  REDIS_PV=$(oc get pvc aap-hub-redis-data -n aap -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
  if [ -n "${REDIS_PV}" ]; then
    REDIS_ZONE=$(oc get pv "${REDIS_PV}" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[?(@.key=="topology.kubernetes.io/zone")].values[0]}' 2>/dev/null || echo "")
    if [ -n "${REDIS_ZONE}" ] && [ "${REDIS_ZONE}" != "${HUB_ZONE}" ]; then
      echo "  Redis PVC bound in zone ${REDIS_ZONE}, need ${HUB_ZONE}. Recreating..."
      oc scale deployment aap-hub-redis -n aap --replicas=0 2>/dev/null || true
      sleep 5
      oc delete pvc aap-hub-redis-data -n aap 2>/dev/null || true
      cat <<REDISPVC | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: aap-hub-redis-data
  namespace: aap
  labels:
    app.kubernetes.io/name: redis
    app.kubernetes.io/instance: aap-hub-redis
    app.kubernetes.io/managed-by: automationhub-operator
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: gp3-csi
REDISPVC
      oc scale deployment aap-hub-redis -n aap --replicas=1 2>/dev/null || true
      echo "  [OK] Redis PVC recreated for zone ${HUB_ZONE}"
    fi
  fi
else
  echo "  [WARN] Could not determine zone. Hub pods will be scheduled by default."
fi

oc scale deployment aap-hub-content -n aap --replicas=1 2>/dev/null || true
oc scale deployment aap-hub-worker -n aap --replicas=1 2>/dev/null || true

echo "  Ensuring Hub route exists for operator health checks..."
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
HUB_ROUTE_EXISTS=$(oc get route aap-hub -n aap -o name 2>/dev/null || echo "")
if [ -z "${HUB_ROUTE_EXISTS}" ] && [ -n "${CLUSTER_DOMAIN}" ]; then
  cat <<RTEOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: aap-hub
  namespace: aap
spec:
  host: aap-hub-aap.${CLUSTER_DOMAIN}
  to:
    kind: Service
    name: aap-hub-web-svc
    weight: 100
  port:
    targetPort: web-8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
RTEOF
  echo "  [OK] Hub route created: aap-hub-aap.${CLUSTER_DOMAIN}"
else
  echo "  [OK] Hub route already exists"
fi

echo "  Waiting for Hub pods to be ready..."
for i in $(seq 1 60); do
  HUB_READY=$(oc get pods -n aap -l 'app.kubernetes.io/managed-by=automationhub-operator' --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "${HUB_READY}" -ge 4 ]; then
    echo "  [OK] Hub pods ready (${HUB_READY} running)"
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    echo "  Waiting... (${HUB_READY} hub pods running)"
  fi
  sleep 10
done

echo "  Waiting for Hub operator reconciliation to complete..."
for i in $(seq 1 60); do
  HUB_FINISHED=$(oc get automationhub aap-hub -n aap -o jsonpath='{.status.conditions[?(@.type=="Automationhub-Operator-Finished-Execution")].status}' 2>/dev/null || echo "")
  if [ "${HUB_FINISHED}" = "True" ]; then
    echo "  [OK] Hub operator reconciliation complete"
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    echo "  Waiting for Hub operator to finish reconciliation (attempt ${i}/60)..."
  fi
  sleep 15
done

echo "  Waiting for AAP reconciliation to succeed..."
for i in $(seq 1 60); do
  AAP_OK=$(oc get aap aap -n aap -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || echo "")
  if [ "${AAP_OK}" = "True" ]; then
    echo "  [OK] AAP reconciliation successful"
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    echo "  Waiting for AAP reconciliation to succeed (attempt ${i}/60)..."
  fi
  sleep 15
done
echo ""

CONTROLLER_HOST=$(oc get route aap -n aap -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
CONTROLLER_PASS=$(oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

if [ -z "${CONTROLLER_HOST}" ]; then
  echo "WARNING: Could not determine AAP controller route. Check AAP deployment."
  echo "You may need to configure AAP manually."
  exit 1
fi

echo "4. Uploading AAP subscription manifest..."
MANIFEST_FILE=$(find "${SCRIPT_DIR}/../ansible/private" -maxdepth 1 -name '*manifest*.zip' -o -name '*subscription*.zip' 2>/dev/null | head -1)
if [ -z "${MANIFEST_FILE}" ]; then
  MANIFEST_FILE=$(find "${SCRIPT_DIR}/../ansible/private" -maxdepth 1 -name '*.zip' 2>/dev/null | head -1)
fi

if [ -n "${MANIFEST_FILE}" ]; then
  LICENSE_TYPE=$(curl -sk -u "admin:${CONTROLLER_PASS}" \
    "https://${CONTROLLER_HOST}/api/controller/v2/config/" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('license_info',{}).get('license_type','NONE'))" 2>/dev/null || echo "NONE")

  if [ "${LICENSE_TYPE}" = "NONE" ] || [ "${LICENSE_TYPE}" = "open" ]; then
    MANIFEST_PAYLOAD=$(mktemp)
    trap 'rm -f "${MANIFEST_PAYLOAD}"' EXIT
    python3 -c "
import base64, json, sys
with open(sys.argv[1], 'rb') as f:
    b64 = base64.b64encode(f.read()).decode()
json.dump({'eula_accepted': True, 'manifest': b64}, open(sys.argv[2], 'w'))
" "${MANIFEST_FILE}" "${MANIFEST_PAYLOAD}"

    HTTP_CODE=$(curl -sk -u "admin:${CONTROLLER_PASS}" \
      -X POST "https://${CONTROLLER_HOST}/api/controller/v2/config/" \
      -H "Content-Type: application/json" \
      -d @"${MANIFEST_PAYLOAD}" \
      -o /dev/null -w "%{http_code}")
    rm -f "${MANIFEST_PAYLOAD}"

    if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 300 ]; then
      echo "  [OK] Subscription manifest uploaded from $(basename "${MANIFEST_FILE}")"
    else
      echo "  [ERROR] Manifest upload failed (HTTP ${HTTP_CODE}). Upload manually via the AAP UI."
      echo "         AAP UI: https://${CONTROLLER_HOST} -> Settings -> Subscription"
    fi
  else
    echo "  [OK] Subscription already active (type: ${LICENSE_TYPE})"
  fi
else
  echo "  [WARN] No manifest .zip found in ansible/private/"
  echo "         Create one at: https://access.redhat.com/management/subscription_allocations"
  echo "         Place the .zip file in ansible/private/ and re-run this script."
  echo "         Or upload manually via: https://${CONTROLLER_HOST} -> Settings -> Subscription"
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
fi

GITEA_ROUTE=$(oc get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
GITEA_PASS=$(oc get secret gitea-admin-credentials -n gitea -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")

echo "5. Building and pushing Self-Healing Agent Execution Environment image..."
EE_DIR="${SCRIPT_DIR}/../ansible/execution-environment"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
EE_IMAGE="${INTERNAL_REGISTRY}/aap/self-healing-ee:latest"

EE_EXISTS=$(oc get istag self-healing-ee:latest -n aap -o name 2>/dev/null || echo "")
if [ -n "${EE_EXISTS}" ]; then
  echo "  [OK] EE image already exists in registry, skipping build"
else
  echo "  Exposing internal registry for image push..."
  oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
    -p '{"spec":{"defaultRoute":true}}' 2>/dev/null || true
  for i in $(seq 1 12); do
    REGISTRY_HOST=$(oc get route default-route -n openshift-image-registry \
      -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${REGISTRY_HOST}" ]; then break; fi
    sleep 5
  done
  if [ -z "${REGISTRY_HOST}" ]; then
    echo "  [ERROR] Could not expose internal registry. Build EE manually."
    echo "         See ansible/execution-environment/README for instructions."
  else
    EE_TAG="${REGISTRY_HOST}/aap/self-healing-ee:latest"
    PULL_SECRET_FILE=$(mktemp)
    trap 'rm -f "${PULL_SECRET_FILE}"' EXIT

    oc get secret pull-secret -n openshift-config \
      -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${PULL_SECRET_FILE}"
    oc whoami -t | podman login --tls-verify=false -u "$(oc whoami)" \
      --password-stdin --authfile "${PULL_SECRET_FILE}" "${REGISTRY_HOST}" 2>/dev/null

    echo "  Building EE with ansible-builder (this takes ~60-90 seconds)..."
    REGISTRY_AUTH_FILE="${PULL_SECRET_FILE}" \
      ansible-builder build \
        --tag "${EE_TAG}" \
        --container-runtime podman \
        --prune-images \
        --no-cache \
        --verbosity 1 \
        -f "${EE_DIR}/execution-environment.yml" \
        -c "${EE_DIR}/context" 2>&1 | while IFS= read -r line; do echo "    ${line}"; done

    if podman image exists "${EE_TAG}" 2>/dev/null; then
      echo "  Pushing EE image to internal registry..."
      REGISTRY_AUTH_FILE="${PULL_SECRET_FILE}" \
        podman push --tls-verify=false "${EE_TAG}" 2>&1 | while IFS= read -r line; do echo "    ${line}"; done

      if oc get istag self-healing-ee:latest -n aap -o name 2>/dev/null | grep -q "self-healing-ee"; then
        echo "  [OK] EE image pushed: ${EE_IMAGE}"
      else
        echo "  [ERROR] EE push may have failed. Check: oc get is -n aap"
      fi
    else
      echo "  [ERROR] EE image build failed. Check ansible-builder output above."
      echo "         You can retry manually:"
      echo "         ansible-builder build --tag ${EE_TAG} --container-runtime podman -f ${EE_DIR}/execution-environment.yml -c ${EE_DIR}/context"
    fi
    rm -f "${PULL_SECRET_FILE}"
    trap - EXIT
  fi
fi
echo ""

echo "6. Configuring AAP resources (credentials, projects, templates, workflow)..."
export CONTROLLER_HOST="https://${CONTROLLER_HOST}"
export CONTROLLER_USERNAME="admin"
export CONTROLLER_PASSWORD="${CONTROLLER_PASS}"
export GITEA_URL="https://${GITEA_ROUTE}"
export GITEA_ADMIN_PASSWORD="${GITEA_PASS}"
export SNOW_INSTANCE="${SNOW_INSTANCE:-}"
export SNOW_ADMIN_USERNAME="${SNOW_ADMIN_USERNAME:-admin}"
export SNOW_ADMIN_PASSWORD="${SNOW_ADMIN_PASSWORD:-}"
export SNOW_AAP_USER_SYSID="${SNOW_AAP_USER_SYSID:-}"
export SNOW_AI_USER_SYSID="${SNOW_AI_USER_SYSID:-}"

export ANSIBLE_CONFIG="${SCRIPT_DIR}/../ansible/ansible.cfg"
TOKEN_FILE="${SCRIPT_DIR}/../ansible/private/rh-enterprise-ansible-galaxy-token.txt"
if [ -f "${TOKEN_FILE}" ]; then
  export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_CERTIFIED_TOKEN="$(cat "${TOKEN_FILE}")"
  export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_VALIDATED_TOKEN="$(cat "${TOKEN_FILE}")"
fi
ansible-playbook "${SCRIPT_DIR}/../ansible/playbooks/configure-aap-resources.yml" \
  -i "${SCRIPT_DIR}/../ansible/inventory/localhost.yml"

echo ""
echo "=== AAP configuration complete ==="
echo "Controller URL: ${CONTROLLER_HOST}"
echo "Username: admin"
echo "Password: (run show-credentials.sh or: oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d)"
echo "Workflow Template: self-healing-workflow"
