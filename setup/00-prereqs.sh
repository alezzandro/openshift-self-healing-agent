#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

MIN_GENERAL_WORKERS=4
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g6.2xlarge}"
GPU_VOLUME_SIZE="${GPU_VOLUME_SIZE:-250}"
NODE_WAIT_TIMEOUT=900   # 15 minutes
NODE_POLL_INTERVAL=30

echo "=== Checking prerequisites ==="
echo ""

ERRORS=0

check_command() {
  if command -v "$1" &>/dev/null; then
    echo "  [OK] $1 found: $(command -v "$1")"
  else
    echo "  [FAIL] $1 not found. $2"
    ERRORS=$((ERRORS + 1))
  fi
}

###############################################################################
# 1. CLI tools
###############################################################################
echo "1. Checking required CLI tools..."
check_command "oc" "Install from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
check_command "podman" "Install: sudo dnf install podman"
check_command "ansible-builder" "Install: pip install ansible-builder"
check_command "ansible-playbook" "Install: pip install ansible-core"
echo ""

###############################################################################
# 2. Cluster access
###############################################################################
echo "2. Checking OpenShift cluster access..."
echo "  [OK] Logged in as: $(oc whoami)"
echo "  [OK] Cluster: $(oc whoami --show-server)"
echo ""

###############################################################################
# 3. Cluster-admin permissions
###############################################################################
echo "3. Checking cluster-admin permissions..."
if oc auth can-i create namespace &>/dev/null; then
  echo "  [OK] User has cluster-admin permissions"
else
  echo "  [FAIL] User does not have cluster-admin permissions"
  ERRORS=$((ERRORS + 1))
fi
echo ""

###############################################################################
# 4. OpenShift version
###############################################################################
echo "4. Checking OpenShift version..."
OCP_VERSION=$(oc version -o json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('openshiftVersion','unknown'))" \
  2>/dev/null || echo "unknown")
echo "  OpenShift version: ${OCP_VERSION}"
echo ""

###############################################################################
# 5. Storage classes
###############################################################################
echo "5. Checking storage classes..."
echo "  Available storage classes:"
oc get storageclass --no-headers 2>/dev/null | while read -r line; do
  echo "    ${line}"
done
echo ""

###############################################################################
# 6. Ansible collections
###############################################################################
echo "6. Installing Ansible collections from Red Hat Automation Hub..."
TOKEN_FILE="${SCRIPT_DIR}/../ansible/private/rh-enterprise-ansible-galaxy-token.txt"
if [ -f "${TOKEN_FILE}" ]; then
  export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_CERTIFIED_TOKEN="$(cat "${TOKEN_FILE}")"
  export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_VALIDATED_TOKEN="$(cat "${TOKEN_FILE}")"
  export ANSIBLE_CONFIG="${SCRIPT_DIR}/../ansible/ansible.cfg"
  ansible-galaxy collection install -r "${SCRIPT_DIR}/../ansible/execution-environment/requirements.yml" --force 2>&1 | tail -5
  echo "  [OK] Ansible collections installed"
else
  echo "  [WARN] Token not found at ansible/private/rh-enterprise-ansible-galaxy-token.txt"
  echo "         Collections must be installed manually. See ansible/private/RH-AutomationHub-instructions.txt"
fi
echo ""

# Bail early if hard prereqs failed -- no point provisioning nodes
if [ "${ERRORS}" -gt 0 ]; then
  echo "=== FAILED: ${ERRORS} prerequisite(s) not met ==="
  exit 1
fi

###############################################################################
# 7. Cluster topology -- node count, GPU provisioning, worker scaling
###############################################################################
echo "7. Checking cluster topology..."
echo ""

# ── Helper: wait for N nodes matching a label selector to be Ready ──────────
wait_for_ready_nodes() {
  local LABEL="$1"
  local NEEDED="$2"
  local DESC="$3"
  local ELAPSED=0

  echo "  Waiting for ${NEEDED} ${DESC} node(s) to reach Ready (timeout ${NODE_WAIT_TIMEOUT}s)..."
  while [ "${ELAPSED}" -lt "${NODE_WAIT_TIMEOUT}" ]; do
    READY_COUNT=$(oc get nodes -l "${LABEL}" --no-headers 2>/dev/null \
      | awk '$2 == "Ready" { n++ } END { print n+0 }')
    if [ "${READY_COUNT}" -ge "${NEEDED}" ]; then
      echo "  [OK] ${READY_COUNT}/${NEEDED} ${DESC} node(s) Ready."
      return 0
    fi
    echo "  ... ${READY_COUNT}/${NEEDED} Ready (${ELAPSED}s elapsed)"
    sleep "${NODE_POLL_INTERVAL}"
    ELAPSED=$((ELAPSED + NODE_POLL_INTERVAL))
  done
  echo "  [WARN] Timeout waiting for ${DESC} nodes. ${READY_COUNT:-0}/${NEEDED} Ready."
  echo "         Nodes may still be provisioning. Continue and re-run this script later."
  return 1
}

# ── Count current nodes ─────────────────────────────────────────────────────
CONTROL_NODES=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l)
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l)
GPU_WORKER_NODES=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l) || GPU_WORKER_NODES=0
GPU_WORKER_NODES_ROLE=$(oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null | wc -l) || GPU_WORKER_NODES_ROLE=0
GPU_TOTAL=$((GPU_WORKER_NODES > GPU_WORKER_NODES_ROLE ? GPU_WORKER_NODES : GPU_WORKER_NODES_ROLE))
GENERAL_WORKERS=$((WORKER_NODES - GPU_TOTAL))

echo "   Node inventory:"
echo "     Control plane nodes:   ${CONTROL_NODES}"
echo "     Worker nodes (total):  ${WORKER_NODES}"
echo "     Worker nodes (general): ${GENERAL_WORKERS}"
echo "     Worker nodes (GPU):    ${GPU_TOTAL}"
echo ""

# ── 7a. GPU worker provisioning ─────────────────────────────────────────────
echo "   7a. Ensuring GPU worker node..."

if [ "${GPU_TOTAL}" -ge 1 ]; then
  echo "  [OK] GPU worker node available."
else
  # Check for existing GPU MachineSets
  GPU_MS_INFO=$(oc get machinesets -n openshift-machine-api -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ms in data.get('items', []):
    name = ms.get('metadata', {}).get('name', '')
    if 'gpu' in name.lower():
        replicas = ms.get('spec', {}).get('replicas', 0)
        print(f'{name}|{replicas}')
        break
" 2>/dev/null || true)

  if [ -n "${GPU_MS_INFO}" ]; then
    GPU_MS_NAME="${GPU_MS_INFO%%|*}"
    GPU_MS_REPLICAS="${GPU_MS_INFO##*|}"
    echo "  Found existing GPU MachineSet: ${GPU_MS_NAME} (replicas=${GPU_MS_REPLICAS})"

    if [ "${GPU_MS_REPLICAS}" -eq 0 ]; then
      echo "  Scaling GPU MachineSet ${GPU_MS_NAME} to 1 replica..."
      oc scale machineset "${GPU_MS_NAME}" -n openshift-machine-api --replicas=1
      wait_for_ready_nodes "node-role.kubernetes.io/worker-gpu" 1 "GPU" || true
    else
      echo "  GPU MachineSet has replicas=${GPU_MS_REPLICAS}, node may still be provisioning."
      wait_for_ready_nodes "node-role.kubernetes.io/worker-gpu" 1 "GPU" || true
    fi
  else
    # No GPU MachineSet exists -- try to create one (AWS only)
    PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || echo "unknown")
    if [ "${PLATFORM}" != "AWS" ]; then
      echo "  [WARN] No GPU nodes or MachineSets found and platform is ${PLATFORM} (not AWS)."
      echo "         Please provision a GPU worker node manually."
    else
      echo "  No GPU MachineSet found. Creating one from existing worker template..."

      GPU_MS_YAML=$(oc get machinesets -n openshift-machine-api -o json 2>/dev/null \
        | python3 -c "
import sys, json, copy

GPU_ROLE = 'worker-gpu'
GPU_INSTANCE_TYPE = '${GPU_INSTANCE_TYPE}'
GPU_VOLUME_SIZE = ${GPU_VOLUME_SIZE}
STRIP_KEYS = ('uid', 'resourceVersion', 'creationTimestamp', 'generation', 'managedFields')

data = json.load(sys.stdin)
items = data.get('items', [])

# Find an active worker MachineSet (role=worker, replicas>=1, not gpu)
source = None
for ms in items:
    tpl_labels = ms.get('spec',{}).get('template',{}).get('metadata',{}).get('labels',{})
    role = tpl_labels.get('machine.openshift.io/cluster-api-machine-role','')
    replicas = ms.get('spec',{}).get('replicas', 0)
    name = ms.get('metadata',{}).get('name','')
    if role == 'worker' and replicas >= 1 and 'gpu' not in name.lower():
        source = ms
        break

if not source:
    print('ERROR: No active worker MachineSet found', file=sys.stderr)
    sys.exit(1)

cluster_id = source['metadata']['labels']['machine.openshift.io/cluster-api-cluster']
az = source['spec']['template']['spec']['providerSpec']['value']['placement']['availabilityZone']
gpu_name = f'{cluster_id}-{GPU_ROLE}-{az}'

gpu = copy.deepcopy(source)

# Strip cluster-managed metadata
meta = gpu.get('metadata', {})
for k in STRIP_KEYS:
    meta.pop(k, None)
gpu.pop('status', None)

# Metadata
meta['name'] = gpu_name
annotations = meta.setdefault('annotations', {})
annotations['machine.openshift.io/GPU'] = '1'
annotations.pop('machine.openshift.io/memoryMb', None)
annotations.pop('machine.openshift.io/vCPU', None)
meta.setdefault('labels', {})['machine.openshift.io/cluster-api-cluster'] = cluster_id

# Replicas
gpu['spec']['replicas'] = 1

# Selector
sel = gpu['spec']['selector']['matchLabels']
sel['machine.openshift.io/cluster-api-cluster'] = cluster_id
sel['machine.openshift.io/cluster-api-machine-role'] = GPU_ROLE
sel['machine.openshift.io/cluster-api-machine-type'] = GPU_ROLE
sel['machine.openshift.io/cluster-api-machineset'] = gpu_name

# Template labels
tl = gpu['spec']['template']['metadata']['labels']
tl['machine.openshift.io/cluster-api-cluster'] = cluster_id
tl['machine.openshift.io/cluster-api-machine-role'] = GPU_ROLE
tl['machine.openshift.io/cluster-api-machine-type'] = GPU_ROLE
tl['machine.openshift.io/cluster-api-machineset'] = gpu_name

# Node labels and taints
node_meta = gpu['spec']['template']['spec'].setdefault('metadata', {})
node_labels = node_meta.setdefault('labels', {})
node_labels[f'node-role.kubernetes.io/{GPU_ROLE}'] = ''

taints = gpu['spec']['template']['spec'].setdefault('taints', [])
if not any(t.get('key') == 'nvidia.com/gpu' for t in taints):
    taints.append({'key': 'nvidia.com/gpu', 'value': 'True', 'effect': 'NoSchedule'})

# Provider spec: instance type and volume
prov = gpu['spec']['template']['spec']['providerSpec']['value']
prov['instanceType'] = GPU_INSTANCE_TYPE
for bd in prov.get('blockDevices', []):
    ebs = bd.get('ebs', {})
    if ebs:
        ebs['volumeSize'] = GPU_VOLUME_SIZE

# Output as YAML-ish JSON (oc apply accepts JSON)
json.dump(gpu, sys.stdout, indent=2)
" 2>/dev/null)

      if [ -z "${GPU_MS_YAML}" ]; then
        echo "  [FAIL] Could not generate GPU MachineSet from existing worker template."
        echo "         Create a GPU MachineSet manually or use ocp-gpu-provisioner-aws."
      else
        GPU_MS_CREATED_NAME=$(echo "${GPU_MS_YAML}" | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata']['name'])" 2>/dev/null)
        echo "  Applying GPU MachineSet: ${GPU_MS_CREATED_NAME}"
        echo "    Instance type: ${GPU_INSTANCE_TYPE}"
        echo "    Volume size:   ${GPU_VOLUME_SIZE} GB"
        echo "    Replicas:      1"
        echo "${GPU_MS_YAML}" | oc apply -f - 2>&1 | while read -r line; do echo "    ${line}"; done
        echo ""
        wait_for_ready_nodes "node-role.kubernetes.io/worker-gpu" 1 "GPU" || true
      fi
    fi
  fi
fi
echo ""

# ── 7b. General worker count ────────────────────────────────────────────────
echo "   7b. Ensuring minimum ${MIN_GENERAL_WORKERS} general worker nodes..."

# Re-count after possible GPU provisioning
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l)
GPU_COUNT=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l) || GPU_COUNT=0
GPU_COUNT_ROLE=$(oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null | wc -l) || GPU_COUNT_ROLE=0
GPU_ACTUAL=$((GPU_COUNT > GPU_COUNT_ROLE ? GPU_COUNT : GPU_COUNT_ROLE))
GENERAL_WORKERS=$((WORKER_NODES - GPU_ACTUAL))

if [ "${GENERAL_WORKERS}" -ge "${MIN_GENERAL_WORKERS}" ]; then
  echo "  [OK] ${GENERAL_WORKERS} general worker nodes (minimum: ${MIN_GENERAL_WORKERS})."
else
  NEEDED=$((MIN_GENERAL_WORKERS - GENERAL_WORKERS))
  echo "  [WARN] Only ${GENERAL_WORKERS} general worker node(s). Need ${NEEDED} more to reach ${MIN_GENERAL_WORKERS}."
  echo ""
  echo "  The worker-node-failure demo scenario cordons and drains a worker. Having"
  echo "  ${MIN_GENERAL_WORKERS} general workers ensures AAP, OpenShift AI, and other critical"
  echo "  self-healing components can be safely rescheduled during the demo."
  echo ""

  # Find the best worker MachineSet to scale
  SCALE_INFO=$(oc get machinesets -n openshift-machine-api -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
best = None
for ms in data.get('items', []):
    name = ms.get('metadata', {}).get('name', '')
    if 'gpu' in name.lower():
        continue
    tpl_labels = ms.get('spec',{}).get('template',{}).get('metadata',{}).get('labels',{})
    role = tpl_labels.get('machine.openshift.io/cluster-api-machine-role','')
    replicas = ms.get('spec',{}).get('replicas', 0)
    if role == 'worker' and replicas >= 1:
        if best is None or replicas > best[1]:
            best = (name, replicas)
if best:
    print(f'{best[0]}|{best[1]}')
" 2>/dev/null || true)

  if [ -z "${SCALE_INFO}" ]; then
    echo "  [WARN] Could not find an active worker MachineSet to scale."
    echo "         Please add worker nodes manually."
  else
    MS_NAME="${SCALE_INFO%%|*}"
    MS_CURRENT="${SCALE_INFO##*|}"
    MS_TARGET=$((MS_CURRENT + NEEDED))

    echo "  MachineSet:      ${MS_NAME}"
    echo "  Current replicas: ${MS_CURRENT}"
    echo "  Target replicas:  ${MS_TARGET}  (+${NEEDED})"
    echo ""
    if [ -t 0 ]; then
      read -rp "  Scale ${MS_NAME} to ${MS_TARGET} replicas? [y/N] " REPLY
    else
      echo "  Non-interactive mode: auto-scaling ${MS_NAME} to ${MS_TARGET} replicas."
      REPLY="y"
    fi
    if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
      echo ""
      echo "  Scaling ${MS_NAME} to ${MS_TARGET} replicas..."
      oc scale machineset "${MS_NAME}" -n openshift-machine-api --replicas="${MS_TARGET}"
      wait_for_ready_nodes "node-role.kubernetes.io/worker,!nvidia.com/gpu.present" \
        "${MIN_GENERAL_WORKERS}" "general worker" || true
    else
      echo ""
      echo "  Skipped. To scale manually:"
      echo "    oc scale machineset ${MS_NAME} -n openshift-machine-api --replicas=${MS_TARGET}"
    fi
  fi
fi
echo ""

###############################################################################
# Final summary
###############################################################################
echo "=== All prerequisites met ==="
