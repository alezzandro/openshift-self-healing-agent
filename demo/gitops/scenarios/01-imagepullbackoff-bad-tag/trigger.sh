#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../setup/ensure-authenticated.sh"

BAD_IMAGE="registry.access.redhat.com/ubi9/httpd-24:vf-demo-bad-tag"
APP_NS="cnf-gitops-demo"
ARGO_NS="openshift-gitops"
ARGO_APP="cnf-sample"
REPO_NAME="cnf-sample"
FILE_PATH="deployment.yaml"
GITEA_NS="gitea"
GITEA_SECRET="gitea-admin-credentials"

echo "=== GitOps Scenario: ImagePullBackOff (bad tag) ==="
echo "This commits a non-existent image tag to the Gitea cnf-sample repo."
echo "OpenShift GitOps (Argo CD) syncs it; pods enter ImagePullBackOff and"
echo "the DemoCNFImagePullBackOff alert fires."
echo ""
echo "Remediation stays in Git (golden JT). Do not live-patch the Deployment."
echo ""

if ! oc get application "${ARGO_APP}" -n "${ARGO_NS}" &>/dev/null; then
  echo "ERROR: Argo CD Application '${ARGO_APP}' not found in ${ARGO_NS}."
  echo "       Run ./setup/09-configure-gitops.sh first."
  exit 1
fi

if ! oc get secret "${GITEA_SECRET}" -n "${GITEA_NS}" &>/dev/null; then
  echo "ERROR: Secret '${GITEA_SECRET}' not found in namespace '${GITEA_NS}'."
  echo "       Run ./setup/04-deploy-gitea.sh first."
  exit 1
fi

GITEA_USER=$(oc get secret "${GITEA_SECRET}" -n "${GITEA_NS}" -o jsonpath='{.data.username}' | base64 -d)
GITEA_PASS=$(oc get secret "${GITEA_SECRET}" -n "${GITEA_NS}" -o jsonpath='{.data.password}' | base64 -d)
GITEA_ROUTE=$(oc get route gitea -n "${GITEA_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [ -z "${GITEA_USER}" ] || [ -z "${GITEA_PASS}" ] || [ -z "${GITEA_ROUTE}" ]; then
  echo "ERROR: Could not read Gitea route or credentials."
  exit 1
fi

echo "Gitea:              https://${GITEA_ROUTE}/${GITEA_USER}/${REPO_NAME}"
echo "Argo Application:   ${ARGO_APP} (${ARGO_NS})"
echo "Workload namespace: ${APP_NS}"
echo "Bad image:          ${BAD_IMAGE}"
echo ""
echo "Current Application status:"
oc get application "${ARGO_APP}" -n "${ARGO_NS}" \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision' 2>/dev/null || true
echo ""
echo "Current pods:"
oc get pods -n "${APP_NS}" -o wide 2>/dev/null || echo "  (namespace ${APP_NS} not found yet)"
echo ""

if [ -t 0 ]; then
  read -rp "Press ENTER to push the bad image tag to Gitea and refresh Argo CD..."
else
  echo "Non-interactive mode: proceeding with bad-tag commit..."
fi

echo ""
echo "Step 1/3: Updating ${FILE_PATH} in Gitea to the bad image..."
UPDATE_RESULT=$(
  GITEA_ROUTE="${GITEA_ROUTE}" \
  GITEA_USER="${GITEA_USER}" \
  GITEA_PASS="${GITEA_PASS}" \
  REPO_NAME="${REPO_NAME}" \
  FILE_PATH="${FILE_PATH}" \
  TARGET_IMAGE="${BAD_IMAGE}" \
  COMMIT_MSG="demo: set cnf-sample image to vf-demo-bad-tag" \
  python3 - <<'PY'
import base64, json, os, re, ssl, sys, urllib.error, urllib.request

route = os.environ["GITEA_ROUTE"]
user = os.environ["GITEA_USER"]
password = os.environ["GITEA_PASS"]
repo = os.environ["REPO_NAME"]
path = os.environ["FILE_PATH"]
target = os.environ["TARGET_IMAGE"]
message = os.environ["COMMIT_MSG"]
url = f"https://{route}/api/v1/repos/{user}/{repo}/contents/{path}"

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
auth = base64.b64encode(f"{user}:{password}".encode()).decode()


def call(method, payload=None):
    headers = {
        "Accept": "application/json",
        "Authorization": f"Basic {auth}",
    }
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, context=ctx) as resp:
        return resp.status, json.loads(resp.read().decode())


try:
    status, body = call("GET")
except urllib.error.HTTPError as exc:
    print(f"ERROR: GET {url} returned HTTP {exc.code}", file=sys.stderr)
    sys.exit(1)

raw = (body.get("content") or "").replace("\n", "")
text = base64.b64decode(raw).decode()
sha = body.get("sha") or ""
if target in text:
    print("UNCHANGED")
    sys.exit(0)

updated, n = re.subn(r"(?m)^(\s*)image:\s*\S+", r"\1image: " + target, text, count=1)
if n == 0:
    print("ERROR: no image: line found in deployment.yaml", file=sys.stderr)
    sys.exit(1)

try:
    call("PUT", {
        "message": message,
        "content": base64.b64encode(updated.encode()).decode(),
        "sha": sha,
        "branch": "main",
    })
except urllib.error.HTTPError as exc:
    print(f"ERROR: PUT {url} returned HTTP {exc.code}", file=sys.stderr)
    sys.exit(1)

print("CHANGED")
PY
)
echo "  [${UPDATE_RESULT}] Gitea ${REPO_NAME}/${FILE_PATH} image=${BAD_IMAGE}"

echo ""
echo "Step 2/3: Forcing Argo CD hard refresh of Application ${ARGO_APP}..."
# Drop a leftover refresh annotation so Argo observes a new hard refresh.
oc -n "${ARGO_NS}" annotate application "${ARGO_APP}" argocd.argoproj.io/refresh- --overwrite 2>/dev/null || true
oc -n "${ARGO_NS}" annotate application "${ARGO_APP}" argocd.argoproj.io/refresh=hard --overwrite
echo "  [OK] Annotated ${ARGO_APP} with argocd.argoproj.io/refresh=hard"

echo ""
echo "Step 3/3: Waiting for a pod in ${APP_NS} to show ImagePullBackOff..."
PULL_SEEN=false
for i in $(seq 1 48); do
  REASONS=$(oc get pods -n "${APP_NS}" \
    -o jsonpath='{range .items[*].status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}' \
    2>/dev/null || true)
  if echo "${REASONS}" | grep -q "ImagePullBackOff"; then
    echo "  [OK] Pod in ${APP_NS} is ImagePullBackOff"
    PULL_SEEN=true
    break
  fi
  if echo "${REASONS}" | grep -q "ErrImagePull"; then
    echo "  Waiting for ImagePullBackOff (attempt ${i}/48, currently ErrImagePull)..."
  elif [ "$((i % 6))" -eq 0 ]; then
    echo "  Waiting for ImagePullBackOff (attempt ${i}/48)..."
  fi
  sleep 5
done

echo ""
oc get pods -n "${APP_NS}" -o wide 2>/dev/null || true
echo ""
oc -n "${ARGO_NS}" annotate application "${ARGO_APP}" argocd.argoproj.io/refresh- --overwrite 2>/dev/null || true

if [ "${PULL_SEEN}" != "true" ]; then
  echo "  [WARN] ImagePullBackOff not observed within ~4 minutes."
  echo "         Argo may still be syncing. Watch pods and Alerting."
fi

echo ""
echo "The DemoCNFImagePullBackOff alert should fire within ~1 minute after"
echo "ImagePullBackOff (PrometheusRule for: 1m). First run: approve and launch"
echo "the Remediate DemoCNFImagePullBackOff Job Template — do not live-patch."
echo ""
echo "Watch Alerting:     OpenShift Console > Observe > Alerting"
echo "Watch EDA:          AAP > Event-Driven Ansible > Rule Audit"
echo "Watch workflow:     AAP > Jobs  (self-healing-workflow)"
echo "Watch ServiceNow:   new INC with RCA; launch JT from Templates"
echo "Watch Argo CD:      Application ${ARGO_APP} health / failed pods"
echo "Watch Gitea:        ${REPO_NAME} commits on deployment.yaml"
echo ""
echo "Watch pods:         oc get pods -n ${APP_NS} -w"
echo ""
echo "To restore the good image:  ./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/cleanup.sh"
echo "To clear EDA throttle:      ./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/reset-eda.sh"
echo "                            (does not wipe the knowledge base or Job Templates)"
