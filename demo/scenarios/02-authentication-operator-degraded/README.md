# Scenario 2: Authentication Operator Degraded

A broken HTPasswd identity provider is added to the cluster's OAuth
configuration, referencing a Secret that does not exist. The authentication
operator cannot validate the configuration and transitions to `Degraded=True`
after its internal debounce period (~90 seconds).

## Infrastructure Layer

**Cluster Authentication** -- affects the operator's ability to reconcile the
OAuth server configuration. Existing user sessions, tokens, and the running
OAuth server pods are completely unaffected. The cluster console, AAP, and all
Routes remain accessible throughout the scenario.

## Alert

| Field | Value |
|-------|-------|
| Alert name | `ClusterOperatorDegraded` |
| Severity | `warning` |
| Key labels | `name=authentication` |
| Default `for` | 10 minutes (overridden to **1 minute** for the demo) |

## What Happens

1. The trigger script adds a broken `HTPasswd` identity provider to the
   `oauth.config.openshift.io/cluster` resource, referencing a non-existent
   Secret (`nonexistent-htpasswd-secret`).
2. The authentication operator's config observation loop detects that the
   referenced Secret does not exist in the `openshift-config` namespace.
3. After a ~90-second debounce period, the `authentication` ClusterOperator
   transitions to `Degraded=True` with reason
   `OAuthServerConfigObservation_Error`.
4. Prometheus fires `ClusterOperatorDegraded{name="authentication"}` and
   Alertmanager sends the webhook to EDA.

## Why This Matters

Identity provider misconfiguration is a common Day-2 operations issue.
Administrators routinely add or modify IDPs during SSO integrations, certificate
rotations, or LDAP/Active Directory changes. A typo in a Secret name, a missing
TLS certificate, or a deleted Keycloak configuration can all cause the
authentication operator to degrade. This scenario is:

- **Safe for demos**: existing sessions and OAuth server pods are unaffected.
  The operator reports Degraded but the running OAuth server continues serving
  authentication requests using the valid (pre-existing) identity providers.
- **Genuinely triggers Degraded=True**: unlike most other operators on OCP 4.21,
  the authentication operator reliably transitions to `Degraded=True` when a
  referenced Secret is missing. No synthetic alerts are needed.
- **Realistic**: mirrors real-world IDP misconfigurations that are difficult to
  detect without infrastructure-level monitoring.

## Demo Script

### 1. Set the stage

> "The OpenShift authentication operator manages the cluster's OAuth server
> and identity providers -- LDAP, OIDC, HTPasswd, and others. When an
> administrator adds or modifies an identity provider, the operator validates
> the configuration and reconciles the OAuth server. If the configuration
> references a Secret that doesn't exist -- perhaps due to a typo during an SSO
> integration or a deleted credential -- the operator degrades. Let's simulate
> that."

Show the current operator status:

```bash
oc get clusteroperator authentication
oc get oauth cluster -o yaml | head -20
```

### 2. Trigger the failure

```bash
./demo/scenarios/02-authentication-operator-degraded/trigger.sh
```

> "We added a broken HTPasswd identity provider that references a Secret named
> `nonexistent-htpasswd-secret`. In production, this could happen when someone
> copies a configuration from a staging cluster without also copying the
> associated Secret, or when a Secret is accidentally deleted during cleanup."

The script waits for the operator to transition to `Degraded=True` (~90 seconds).

### 3. Watch the alert fire

Switch to the **OpenShift Console** > Observe > Alerting.

> "The `ClusterOperatorDegraded` alert fires with the label
> `name=authentication`. The same alert definition covers all cluster
> operators -- the self-healing agent reads the `name` label to understand
> which operator is affected and collects operator-specific diagnostics."

### 4. Walk through the workflow

Open the running workflow job in **AAP** > Jobs:

- **Gather Diagnostics**: Show the output -- note the authentication operator
  status showing `Degraded=True` with the error message about the missing
  Secret.
- **Create ServiceNow Incident**: Switch to ServiceNow to show the new INC
  with cluster diagnostics attached.
- **Check Knowledge Base**: First run takes the "new incident" path. Re-runs
  take the "known incident" path and auto-launch the existing template.
- **AI Root Cause Analysis**: The AI identifies the missing Secret reference
  and generates a playbook to remove the broken identity provider.

### 5. Show the generated playbook

In **Gitea** > `remediation-playbooks`:

> "The AI generated a playbook that uses `kubernetes.core.k8s` to patch the
> OAuth configuration and remove the broken identity provider entry. The
> operator name is a variable, making the playbook reusable for similar
> misconfigurations."

### 6. Highlight the safety aspect

> "Notice that during this entire incident, you could still log in to the
> OpenShift Console, AAP, and all other Routes. The authentication operator
> reported Degraded, but the running OAuth server pods were never affected --
> they continued serving requests using the existing valid identity providers.
> This is a critical distinction: operator degradation does not mean service
> outage. The self-healing agent detects and resolves the configuration issue
> before it could escalate into an actual authentication failure."

## Expected Outcome

- The `authentication` ClusterOperator is identified as Degraded.
- The AI diagnoses the missing Secret reference as the root cause.
- A remediation playbook to remove the broken IDP is generated and stored.
- ServiceNow incident tracks the full lifecycle.
- On re-trigger, the known-incident path launches the existing template
  automatically.

## Cleanup

```bash
./demo/scenarios/02-authentication-operator-degraded/cleanup.sh
```

Or reset the full environment:

```bash
./setup/reset-demo.sh
```
