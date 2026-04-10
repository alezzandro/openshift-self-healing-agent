#!/bin/bash
###############################################################################
#  reset-eda.sh  — Restart the EDA activation to clear throttle state
#
#  The EDA rulebook uses `once_within: 3 hours` per alert name, which means
#  a second trigger of the same alert is silently ignored for 3 hours.
#  Restarting the activation resets this in-memory throttle window.
#
#  This does NOT wipe the knowledge base, Job Templates, Gitea playbooks,
#  or ServiceNow incidents.  It ONLY restarts the EDA activation.
#
#  Usage:
#    ./demo/reset-eda.sh                         # standalone
#    ./demo/scenarios/<uc>/reset-eda.sh           # per-UC wrapper calls this
###############################################################################
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../setup/ensure-authenticated.sh"

echo "=== Restarting EDA Activation (clearing throttle state) ==="
echo ""

AAP_GW_HOST=$(oc get route aap -n aap -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "${AAP_GW_HOST}" ]; then
  echo "  [ERROR] Could not determine AAP Gateway route. Is AAP deployed?"
  exit 1
fi
AAP_GW="https://${AAP_GW_HOST}"
AAP_PASS=$(oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d)

RBA_INFO=$(curl -sk -u "admin:${AAP_PASS}" \
  "${AAP_GW}/api/eda/v1/activations/?name=Cluster+Alert+Handler" \
  -H 'Accept: application/json' 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('results', [])
if results:
    r = results[0]
    print(f\"{r['id']}|{r.get('status','unknown')}\")
" 2>/dev/null || echo "")

if [ -z "${RBA_INFO}" ]; then
  echo "  [ERROR] EDA activation 'Cluster Alert Handler' not found."
  echo "         Check the EDA configuration in AAP."
  exit 1
fi

RBA_ID="${RBA_INFO%%|*}"
RBA_STATUS="${RBA_INFO##*|}"
echo "  Activation ID: ${RBA_ID}  (current status: ${RBA_STATUS})"

# --- Disable ---
echo "  Disabling activation..."
curl -sk -u "admin:${AAP_PASS}" \
  "${AAP_GW}/api/eda/v1/activations/${RBA_ID}/disable/" \
  -X POST -H 'Content-Type: application/json' -o /dev/null 2>/dev/null || true

EDA_STOPPED=false
for i in $(seq 1 24); do
  sleep 5
  ST=$(curl -sk -u "admin:${AAP_PASS}" \
    "${AAP_GW}/api/eda/v1/activations/${RBA_ID}/" \
    -H 'Accept: application/json' 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
  if [ "${ST}" = "completed" ] || [ "${ST}" = "stopped" ]; then
    EDA_STOPPED=true
    break
  fi
  if [ "$((i % 4))" -eq 0 ]; then
    echo "    Waiting for activation to stop... (status: ${ST})"
  fi
done

if ! ${EDA_STOPPED}; then
  echo "  [ERROR] Activation did not stop within 2 minutes."
  echo "         Disable and re-enable it manually in the AAP UI."
  exit 1
fi

# --- Re-enable ---
echo "  Re-enabling activation..."
curl -sk -u "admin:${AAP_PASS}" \
  "${AAP_GW}/api/eda/v1/activations/${RBA_ID}/enable/" \
  -X POST -H 'Content-Type: application/json' -o /dev/null 2>/dev/null || true

EDA_RUNNING=false
for i in $(seq 1 24); do
  sleep 5
  ST=$(curl -sk -u "admin:${AAP_PASS}" \
    "${AAP_GW}/api/eda/v1/activations/${RBA_ID}/" \
    -H 'Accept: application/json' 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
  if [ "${ST}" = "running" ]; then
    EDA_RUNNING=true
    break
  fi
  if [ "$((i % 4))" -eq 0 ]; then
    echo "    Waiting for activation to start... (status: ${ST})"
  fi
done

if ${EDA_RUNNING}; then
  echo ""
  echo "  [OK] EDA activation restarted — throttle state cleared."
  echo "       The next alert will be processed immediately."
else
  echo ""
  echo "  [ERROR] Activation did not reach 'running' state."
  echo "         Re-enable it manually in the AAP UI."
  exit 1
fi
