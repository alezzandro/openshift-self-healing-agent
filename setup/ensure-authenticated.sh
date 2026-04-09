#!/bin/bash
###############################################################################
#  ensure-authenticated.sh  — Verify OCP session is active, re-login if not
#
#  Source this script at the top of any script that talks to the cluster:
#    source "$(dirname "${BASH_SOURCE[0]}")/../setup/ensure-authenticated.sh"
#
#  What it does:
#    1. Checks that `oc` CLI is installed.
#    2. Runs `oc whoami` to verify the session token is still valid.
#    3. If the token is expired it offers interactive re-login via `oc login`.
#    4. Exits non-zero if authentication cannot be established.
###############################################################################

_ensure_oc_authenticated() {
  if ! command -v oc &>/dev/null; then
    echo ""
    echo "  ERROR: 'oc' CLI not found."
    echo "  Install it from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
    exit 1
  fi

  if oc whoami &>/dev/null; then
    return 0
  fi

  echo ""
  echo "  ┌────────────────────────────────────────────────────────┐"
  echo "  │  OpenShift session expired or not logged in.           │"
  echo "  └────────────────────────────────────────────────────────┘"

  local CLUSTER_URL
  CLUSTER_URL=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")

  if [ -n "${CLUSTER_URL}" ]; then
    echo "  Cluster API: ${CLUSTER_URL}"
  fi
  echo ""

  if [ -t 0 ]; then
    read -rp "  Would you like to log in now? [Y/n] " REPLY
    REPLY=${REPLY:-Y}
    if [[ "${REPLY}" =~ ^[Yy] ]]; then
      echo ""
      if [ -n "${CLUSTER_URL}" ]; then
        read -rp "  Username [admin]: " OC_USER
        OC_USER=${OC_USER:-admin}
        read -rsp "  Password: " OC_PASS
        echo ""
        if oc login "${CLUSTER_URL}" -u "${OC_USER}" -p "${OC_PASS}" --insecure-skip-tls-verify=true; then
          echo "  [OK] Logged in as $(oc whoami)"
          echo ""
          return 0
        fi
      else
        echo "  No cluster URL found in kubeconfig."
        echo "  Run manually:  oc login <cluster-api-url>"
      fi
    fi
  fi

  echo ""
  echo "  ERROR: Not authenticated to OpenShift."
  echo "  Run:   oc login <cluster-api-url>"
  exit 1
}

_ensure_oc_authenticated
