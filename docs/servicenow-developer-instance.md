# ServiceNow Developer Instance Setup

## Requesting a Developer Instance

1. Go to [developer.servicenow.com](https://developer.servicenow.com/)
2. Create a free account or sign in
3. Navigate to **Manage** > **Instance** > **Request Instance**
4. Select the latest available release (e.g., "Xanadu" or newer)
5. Wait for provisioning (typically 5-10 minutes)
6. Note down:
   - **Instance URL**: `https://<instance-id>.service-now.com`
   - **Admin username**: `admin`
   - **Admin password**: (shown on the instance page)

## Important Notes

- Developer instances **hibernate after 10 days of inactivity**
- To wake a hibernating instance: go to your developer portal and click **Wake Instance**
- After waking, all data is preserved but the instance takes 5-10 minutes to start
- Instances are **reclaimed after 30 days** of inactivity -- log in periodically

## Automated Configuration

Once you have a running instance, the demo setup script handles everything else
automatically:

```bash
./setup/05-configure-servicenow.sh
```

This script will prompt you for:
- ServiceNow instance URL
- Admin username and password

It then runs the `setup-servicenow.yml` Ansible playbook which:

1. **Creates service accounts**:
   - `svc-aap-automation` (role: `itil`) -- identity used for AAP-originated work notes
   - `svc-ai-agent` (role: `itil`) -- identity used for AI-originated work notes
2. **Cleans up demo data**: purges existing test incidents
3. **Outputs credentials**: writes to `setup/.servicenow-credentials.env` (git-ignored),
   including admin credentials and user `sys_id` values for impersonation

## Credential Usage

Ansible playbooks authenticate to ServiceNow with admin credentials and use the
[Impersonation API](https://docs.servicenow.com/bundle/latest/page/integrate/inbound-rest/concept/c_RESTAPI.html)
to attribute actions to the appropriate service account.

| User | Impersonated By | Purpose |
|------|-----------------|---------|
| `svc-aap-automation` | `create-servicenow-incident.yml` | Create incidents, attach diagnostics |
| `svc-ai-agent` | `invoke-ai-new-incident.yml`, `invoke-ai-known-incident.yml` | Post RCA and remediation details |

## Troubleshooting

### Instance not responding after wake
Wait 5-10 minutes. The instance needs time to fully start all services.

### Password reset
Go to the developer portal, select your instance, and use the **Reset admin password** option.

### Re-running setup
The setup playbook is idempotent. Re-running it will:
- Skip user creation if users already exist (update passwords instead)
- Re-clean incidents
- Regenerate the credentials file
