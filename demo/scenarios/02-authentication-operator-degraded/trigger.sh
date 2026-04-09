#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../setup/ensure-authenticated.sh"

echo "=== Scenario 2: Authentication Operator Degraded ==="
echo "This will add a broken HTPasswd identity provider that references a"
echo "non-existent Secret, causing the authentication operator to report"
echo "Degraded=True.  Existing logins and sessions are NOT affected."
echo ""

echo "Current authentication operator status:"
oc get clusteroperator authentication
echo ""

BROKEN_IDP=$(oc get oauth cluster -o json 2>/dev/null \
  | python3 -c "
import sys, json
idps = json.load(sys.stdin).get('spec', {}).get('identityProviders', [])
for idp in idps:
    if idp.get('name') == 'broken-htpasswd-demo':
        print('found')
        break
" 2>/dev/null || echo "")

if [ "${BROKEN_IDP}" = "found" ]; then
  echo "WARNING: The broken IDP 'broken-htpasswd-demo' already exists."
  echo "Run cleanup.sh first to remove it, then trigger again."
  exit 1
fi

if [ -t 0 ]; then
  read -rp "Press ENTER to inject the broken identity provider..."
else
  echo "Non-interactive mode: proceeding with broken identity provider injection..."
fi

echo ""
echo "Adding a broken HTPasswd IDP referencing a non-existent Secret..."
oc patch oauth cluster --type json \
  -p '[{"op":"add","path":"/spec/identityProviders/-","value":{"name":"broken-htpasswd-demo","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"nonexistent-htpasswd-secret"}}}}]'

echo ""
echo "Waiting for the authentication operator to report Degraded=True..."
echo "(The operator has a ~90s debounce period before transitioning.)"
echo ""

FOUND=false
for i in $(seq 1 30); do
  sleep 5
  D=$(oc get clusteroperator authentication \
    -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "")
  R=$(oc get clusteroperator authentication \
    -o jsonpath='{.status.conditions[?(@.type=="Degraded")].reason}' 2>/dev/null || echo "")
  M=$(oc get clusteroperator authentication \
    -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null | head -c 120 || echo "")
  echo "  [${i}/30] Degraded=${D} reason=${R}"
  if [ "${D}" = "True" ]; then
    FOUND=true
    echo ""
    echo "  [OK] Authentication operator is now Degraded=True"
    echo "  Message: ${M}"
    break
  fi
done

echo ""
oc get clusteroperator authentication
echo ""

if ${FOUND}; then
  echo "[OK] The ClusterOperatorDegraded alert will fire within ~1 minute."
  echo "     Alertmanager will then send the webhook to EDA automatically."
else
  echo "[WARN] Operator has not transitioned to Degraded=True yet."
  echo "       It may need more time. Monitor with:"
  echo "         oc get clusteroperator authentication -w"
fi

echo ""
echo "Watch workflow:  AAP > Jobs (look for 'self-healing-workflow')"
echo "Watch operator:  oc get clusteroperator authentication -w"
echo ""
echo "To clean up:  ./demo/scenarios/02-authentication-operator-degraded/cleanup.sh"
