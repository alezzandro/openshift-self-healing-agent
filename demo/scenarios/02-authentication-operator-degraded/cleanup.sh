#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../setup/ensure-authenticated.sh"

echo "=== Cleanup: Authentication Operator Degraded ==="

BROKEN_IDP=$(oc get oauth cluster -o json 2>/dev/null \
  | python3 -c "
import sys, json
idps = json.load(sys.stdin).get('spec', {}).get('identityProviders', [])
for i, idp in enumerate(idps):
    if idp.get('name') == 'broken-htpasswd-demo':
        print(i)
        break
" 2>/dev/null || echo "")

if [ -z "${BROKEN_IDP}" ]; then
  echo "The broken IDP 'broken-htpasswd-demo' is not present in the OAuth config."
  echo "Nothing to clean up."
  oc get clusteroperator authentication
  exit 0
fi

echo "Removing the 'broken-htpasswd-demo' identity provider (index ${BROKEN_IDP})..."
oc patch oauth cluster --type json \
  -p "[{\"op\":\"remove\",\"path\":\"/spec/identityProviders/${BROKEN_IDP}\"}]"

echo ""
echo "Waiting for authentication operator to recover..."
for i in $(seq 1 60); do
  DEGRADED=$(oc get clusteroperator authentication \
    -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "")
  AVAILABLE=$(oc get clusteroperator authentication \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  if [ "${AVAILABLE}" = "True" ] && [ "${DEGRADED}" = "False" ]; then
    echo "  [OK] Authentication operator is Available and not Degraded."
    break
  fi
  if [ "$((i % 6))" -eq 0 ]; then
    echo "  Attempt ${i}/60 -- Available=${AVAILABLE:-pending} Degraded=${DEGRADED:-pending}"
  fi
  sleep 5
done

echo ""
echo "Cleanup complete."
oc get clusteroperator authentication
