#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../setup/ensure-authenticated.sh"

GOOD_IMAGE="registry.access.redhat.com/ubi9/httpd-24:latest"
APP_NS="cnf-gitops-demo"
ARGO_NS="openshift-gitops"
ARGO_APP="cnf-sample"
REPO_NAME="cnf-sample"
FILE_PATH="deployment.yaml"
GITEA_NS="gitea"
GITEA_SECRET="gitea-admin-credentials"

echo "=== Cleanup: ImagePullBackOff (bad tag) ==="
echo "Restores the known-good UBI httpd image in Gitea and waits for"
echo "OpenShift GitOps to sync Application ${ARGO_APP}."
echo ""

if ! oc get secret "${GITEA_SECRET}" -n "${GITEA_NS}" &>/dev/null; then
  echo "ERROR: Secret '${GITEA_SECRET}' not found in namespace '${GITEA_NS}'."
  exit 1
fi

GITEA_USER=$(oc get secret "${GITEA_SECRET}" -n "${GITEA_NS}" -o jsonpath='{.data.username}' | base64 -d)
GITEA_PASS=$(oc get secret "${GITEA_SECRET}" -n "${GITEA_NS}" -o jsonpath='{.data.password}' | base64 -d)
GITEA_ROUTE=$(oc get route gitea -n "${GITEA_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [ -z "${GITEA_USER}" ] || [ -z "${GITEA_PASS}" ] || [ -z "${GITEA_ROUTE}" ]; then
  echo "ERROR: Could not read Gitea route or credentials."
  exit 1
fi

if ! oc get application "${ARGO_APP}" -n "${ARGO_NS}" &>/dev/null; then
  echo "ERROR: Argo CD Application '${ARGO_APP}' not found in ${ARGO_NS}."
  echo "       Run ./setup/09-configure-gitops.sh first."
  exit 1
fi

echo "Step 1/3: Restoring ${FILE_PATH} in Gitea to the known-good image..."
UPDATE_RESULT=$(
  GITEA_ROUTE="${GITEA_ROUTE}" \
  GITEA_USER="${GITEA_USER}" \
  GITEA_PASS="${GITEA_PASS}" \
  REPO_NAME="${REPO_NAME}" \
  FILE_PATH="${FILE_PATH}" \
  TARGET_IMAGE="${GOOD_IMAGE}" \
  COMMIT_MSG="fix: restore cnf-sample image for self-healing demo" \
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
echo "  [${UPDATE_RESULT}] Gitea ${REPO_NAME}/${FILE_PATH} image=${GOOD_IMAGE}"

echo ""
echo "Step 2/3: Forcing Argo CD hard refresh of Application ${ARGO_APP}..."
oc -n "${ARGO_NS}" annotate application "${ARGO_APP}" argocd.argoproj.io/refresh- --overwrite 2>/dev/null || true
oc -n "${ARGO_NS}" annotate application "${ARGO_APP}" argocd.argoproj.io/refresh=hard --overwrite
echo "  [OK] Annotated ${ARGO_APP} with argocd.argoproj.io/refresh=hard"

echo ""
echo "Step 3/3: Waiting for Deployment ${ARGO_APP} in ${APP_NS} to become Available..."
DEPLOY_OK=false
for i in $(seq 1 36); do
  LIVE_IMAGE=$(oc get deploy "${ARGO_APP}" -n "${APP_NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
  AVAIL=$(oc get deploy "${ARGO_APP}" -n "${APP_NS}" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
  WAITING=$(oc get pods -n "${APP_NS}" \
    -o jsonpath='{range .items[*].status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}' \
    2>/dev/null || true)
  if [ "${LIVE_IMAGE}" = "${GOOD_IMAGE}" ] && [ "${AVAIL}" != "0" ] && [ -n "${AVAIL}" ] \
     && ! echo "${WAITING}" | grep -q "ImagePullBackOff"; then
    echo "  [OK] Deployment Available with ${GOOD_IMAGE}"
    DEPLOY_OK=true
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    echo "  Attempt ${i}/36 -- image=${LIVE_IMAGE:-pending} available=${AVAIL:-0}"
  fi
  sleep 5
done

oc -n "${ARGO_NS}" annotate application "${ARGO_APP}" argocd.argoproj.io/refresh- --overwrite 2>/dev/null || true

echo ""
oc get deploy,pods -n "${APP_NS}" 2>/dev/null || true
echo ""
oc get application "${ARGO_APP}" -n "${ARGO_NS}" \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null || true

if [ "${DEPLOY_OK}" != "true" ]; then
  echo ""
  echo "  [WARN] Deployment did not become Available with the known-good image"
  echo "         within ~3 minutes. Check Argo CD Application ${ARGO_APP}."
fi

echo ""
echo "Cleanup complete."
echo ""
echo "If a re-demo is blocked by EDA throttle (once_within: 3 hours), run:"
echo "  ./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/reset-eda.sh"
echo "That restarts the activation only — it does not wipe the knowledge base."
