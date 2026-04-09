# Reference: kubernetes.core Ansible Collection — Module Usage

## kubernetes.core.k8s_drain — Correct Usage

The `state:` parameter is REQUIRED. Valid values: `drain` or `uncordon`.

All drain flags go INSIDE `delete_options:` — NOT at the top level.

### Valid Top-Level Parameters
- `name` — the node name
- `state` — `drain` or `uncordon`
- `delete_options` — dict of drain behavior options
- `label_selectors` — list of label selector strings
- `pod_selectors` — list of pod selector strings

### Valid Keys Inside delete_options
- `delete_emptydir_data` — remove pods using emptyDir volumes
- `disable_eviction` — bypass eviction API (use delete instead)
- `force` — force drain even if there are unmanaged pods
- `ignore_daemonsets` — ignore DaemonSet pods
- `terminate_grace_period` — override pod termination grace period
- `wait_sleep` — seconds between drain checks
- `wait_timeout` — total seconds to wait for drain

### WRONG — These Are NOT Valid at Top Level
`delete_local_data`, `ignore_daemonsets`, `grace_period`, `force`,
`delete_emptydir_data` — placing these at the top level causes a runtime error.
The correct parameter name is `terminate_grace_period`, not `grace_period`.

### Correct Example
```yaml
- name: Drain the affected node
  kubernetes.core.k8s_drain:
    name: "{{ target_node }}"
    state: drain
    delete_options:
      ignore_daemonsets: true
      delete_emptydir_data: true
      force: true
      disable_eviction: true
      terminate_grace_period: 30
```

## kubernetes.core label_selectors

`label_selectors` is a list of STRINGS, not dicts.

### Correct
```yaml
label_selectors:
  - "machine.openshift.io/cluster-api-machine-role=worker"
```

### WRONG (will error)
```yaml
label_selectors:
  - key: "node-role.kubernetes.io/worker"
    operator: In
    values: ["true"]
```

## Counting Ready Worker Nodes — Correct Jinja2 Pattern

Use this pattern to count how many nodes have the Ready condition set to True:

```yaml
- name: Wait for expected Ready worker count
  kubernetes.core.k8s_info:
    api_version: v1
    kind: Node
    label_selectors:
      - "node-role.kubernetes.io/worker"
  register: worker_nodes
  until: >-
    (worker_nodes.resources
     | selectattr('status.conditions', 'defined')
     | map(attribute='status.conditions')
     | map('selectattr', 'type', 'equalto', 'Ready')
     | map('selectattr', 'status', 'equalto', 'True')
     | map('list') | select | list | length)
    >= (expected_worker_count | int)
  retries: 40
  delay: 30
```

Do NOT use `match` with a dict inside `selectattr` — that is not valid
Ansible Jinja2 and causes a YAML parse error.
