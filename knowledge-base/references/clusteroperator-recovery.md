# Reference: Waiting for a ClusterOperator to Recover

Use this pattern to verify a ClusterOperator has returned to healthy state
after a remediation action.

## Wait Pattern

```yaml
- name: Wait for operator to recover
  kubernetes.core.k8s_info:
    api_version: config.openshift.io/v1
    kind: ClusterOperator
    name: "{{ target_operator }}"
  register: co_status
  until: >-
    (co_status.resources[0].status.conditions
     | selectattr('type', 'equalto', 'Degraded')
     | map(attribute='status') | list | first) == 'False'
    and
    (co_status.resources[0].status.conditions
     | selectattr('type', 'equalto', 'Available')
     | map(attribute='status') | list | first) == 'True'
  retries: 40
  delay: 15
```

## What This Checks
- `Degraded` condition status is `'False'`
- `Available` condition status is `'True'`

Both conditions must be met simultaneously for the operator to be considered
healthy.

## Key Details
- The `retries: 40` and `delay: 15` provide up to 10 minutes of wait time.
- The condition values are strings (`'True'`, `'False'`), not booleans.
- Use `selectattr` and `map` to extract the condition safely.
