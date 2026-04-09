# Runbook: ClusterOperatorDegraded (general)

## Alert
ClusterOperatorDegraded fires when any ClusterOperator reports Degraded=True.

## Diagnosis
1. Identify the degraded operator from the alert details.
2. Query the ClusterOperator status conditions using `kubernetes.core.k8s_info`
   with `api_version: config.openshift.io/v1`, `kind: ClusterOperator`, and
   `name:` set to the operator name.
3. Read the Degraded condition's `reason` and `message` fields to understand
   the root cause.

## Approved Remediation
Remediate the underlying resource that is causing the degraded state. The
fix depends on the specific operator and the reason for degradation.

After applying the fix, verify the operator returns to a healthy state:
- Available=True
- Degraded=False

Use a retry loop (retries: 40, delay: 15) to wait for the operator to
recover.

## Variables
- `target_operator`: the name of the degraded ClusterOperator (required)
