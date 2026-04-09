# Runbook: KubeNodeNotReady

## Alert
KubeNodeNotReady — a worker node is reporting a NotReady condition.

## Root Cause
The most common causes are kubelet failure, loss of network connectivity,
kernel panic, or system-level resource exhaustion (OOM, disk full).

## Approved Remediation — Node Replacement
The approved practice for KubeNodeNotReady is node replacement, not recovery.
Do NOT attempt to restart the kubelet or SSH into the node to recover it.

### Steps
1. Drain the affected node using `kubernetes.core.k8s_drain` with
   `state: drain`. Set all drain flags inside `delete_options:` — specifically
   `ignore_daemonsets: true`, `delete_emptydir_data: true`,
   `disable_eviction: true`, and `force: true`.
2. Look up the Machine object in the `openshift-machine-api` namespace that
   backs the affected node. Filter machines by the worker role label
   `machine.openshift.io/cluster-api-machine-role=worker` and match via
   `status.nodeRef.name` equal to the target node name.
3. Delete the Machine using `kubernetes.core.k8s` with `state: absent`.
   The MachineSet controller automatically provisions a replacement machine
   with a new hostname.
4. Wait until the total count of Ready worker nodes reaches the expected
   number (use an `expected_worker_count` variable, default 3). Do NOT
   verify by re-querying the original node name — it no longer exists.

## Variables
- `target_node`: the name of the NotReady worker node (required)
- `expected_worker_count`: the expected total number of Ready workers (default 3)
