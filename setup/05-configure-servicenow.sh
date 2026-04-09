#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Configuring ServiceNow Developer Instance ==="
echo ""
echo "This script creates service accounts and cleans up demo data."
echo "You need a running ServiceNow Developer Instance."
echo "See: docs/servicenow-developer-instance.md"
echo ""

CREDS_FILE="${SCRIPT_DIR}/.servicenow-credentials.env"

if [ -t 0 ]; then
  read -rp "ServiceNow Instance URL (e.g. https://dev12345.service-now.com): " SNOW_URL
  read -rp "Admin Username [admin]: " SNOW_USER
  SNOW_USER="${SNOW_USER:-admin}"
  read -rsp "Admin Password: " SNOW_PASS
  echo ""
elif [ -f "${CREDS_FILE}" ]; then
  echo "Non-interactive mode: loading credentials from ${CREDS_FILE}"
  source "${CREDS_FILE}"
  SNOW_URL="${SNOW_INSTANCE}"
  SNOW_USER="${SNOW_ADMIN_USERNAME:-admin}"
  SNOW_PASS="${SNOW_ADMIN_PASSWORD}"
else
  echo "[ERROR] Non-interactive mode requires either:"
  echo "  - An existing ${CREDS_FILE} from a previous run, or"
  echo "  - An interactive terminal to prompt for ServiceNow credentials."
  exit 1
fi

echo ""
echo "Running ServiceNow setup playbook..."
export ANSIBLE_CONFIG="${SCRIPT_DIR}/../ansible/ansible.cfg"
TOKEN_FILE="${SCRIPT_DIR}/../ansible/private/rh-enterprise-ansible-galaxy-token.txt"
if [ -f "${TOKEN_FILE}" ]; then
  export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_CERTIFIED_TOKEN="$(cat "${TOKEN_FILE}")"
  export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_VALIDATED_TOKEN="$(cat "${TOKEN_FILE}")"
fi
ansible-playbook "${SCRIPT_DIR}/../ansible/playbooks/setup-servicenow.yml" \
  -i "${SCRIPT_DIR}/../ansible/inventory/localhost.yml" \
  -e "snow_instance_url=${SNOW_URL}" \
  -e "snow_admin_username=${SNOW_USER}" \
  -e "snow_admin_password=${SNOW_PASS}"

echo ""
if [ -f "${SCRIPT_DIR}/.servicenow-credentials.env" ]; then
  echo "=== ServiceNow configuration complete ==="
  echo "Credentials saved to: setup/.servicenow-credentials.env"
  echo ""
  echo "Users created:"
  grep "SNOW_" "${SCRIPT_DIR}/.servicenow-credentials.env" | grep -v "^#" | grep USERNAME
else
  echo "WARNING: Credentials file not found. Check playbook output for errors."
fi
