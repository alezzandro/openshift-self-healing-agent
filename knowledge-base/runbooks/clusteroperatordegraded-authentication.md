# Runbook: ClusterOperatorDegraded — authentication operator

## Alert
ClusterOperatorDegraded fires when the authentication ClusterOperator reports
Degraded=True.

## Root Cause
The most common root cause is a misconfigured identity provider (IDP) in the
OAuth configuration that references a Secret which does not exist in the
`openshift-config` namespace. A missing secret causes the authentication
operator to enter a Degraded state.

## Approved Remediation — Remove the Broken IDP
The fix is to REMOVE the broken identity provider from the OAuth resource.
Do NOT restart pods — this is a configuration issue, not a pod failure.
Do NOT query the Authentication CRD (config.openshift.io/v1 kind: Authentication)
— query the ClusterOperator and OAuth resources instead.

### Steps
1. Query the OAuth resource:
   - api_version: config.openshift.io/v1
   - kind: OAuth
   - name: cluster
   Retrieve `spec.identityProviders`.
2. Loop over each IDP and check whether its referenced Secret exists in the
   `openshift-config` namespace using `kubernetes.core.k8s_info`:
   - HTPasswd type → secret name is at `.htpasswd.fileData.name`
   - OpenID type   → secret name is at `.openID.clientSecret.name`
   - LDAP type     → secret name is at `.ldap.bindPassword.name`
   - Keystone type → secret name is at `.keystone.ca.name`
3. Build a filtered list containing ONLY the IDPs whose referenced Secrets
   were found (use `set_fact` with a loop).
4. Patch the OAuth resource with the filtered list using `kubernetes.core.k8s`:
   ```
   kubernetes.core.k8s:
     state: present
     api_version: config.openshift.io/v1
     kind: OAuth
     name: cluster
     definition:
       spec:
         identityProviders: "{{ valid_idps }}"
   ```
5. Wait for ClusterOperator `authentication` to reach Degraded=False,
   Available=True (use the ClusterOperator recovery wait pattern with
   retries: 40 and delay: 15).

## Critical Rules
- CRITICAL: Do NOT restart pods — this is a configuration issue.
- CRITICAL: Do NOT query the Authentication CRD.
- The playbook MUST use variables: `target_operator` (default 'authentication'),
  `target_oauth_name` (default 'cluster').
