# Scenario 3: Node Disk Pressure

A worker node's filesystem fills up past the critical threshold. The kubelet
begins evicting pods, applies the `node.kubernetes.io/disk-pressure:NoSchedule`
taint, and the node can no longer accept new workloads.

## Infrastructure Layer

**Node Resources** -- affects the kubelet's ability to run and schedule
workloads on the affected node due to insufficient disk space.

## Alert

| Field | Value |
|-------|-------|
| Alert name | `NodeFilesystemSpaceFillingUp` |
| Severity | `warning` |
| Key labels | `instance=<node>`, `device=<block-device>`, `mountpoint=<path>` |
| Default `for` | 6 hours / 4 hours (overridden to **1 minute** for the demo) |

## What Happens

1. The trigger script selects a non-GPU worker node with the fewest critical
   pods (same safe-selection logic as Scenario 1).
2. A large file (~85% of disk capacity) is written to `/var/tmp/` on the node
   via `oc debug node/` using `dd`.
3. The kubelet detects that available disk space dropped below the eviction
   threshold and sets `DiskPressure=True`.
4. Prometheus fires `NodeFilesystemSpaceFillingUp` and Alertmanager sends the
   webhook to EDA.

## Why This Matters

Disk pressure is one of the most frequent infrastructure issues in production
Kubernetes clusters. It can be caused by:

- Accumulated container images and layers not being garbage-collected
- Application logs writing to `emptyDir` volumes on the host filesystem
- Orphaned pod data in `/var/lib/kubelet`
- Large core dumps or crash artifacts

Unlike application-level issues, disk pressure requires **node-specific
diagnosis** -- identifying which filesystem is affected, what is consuming
space, and how to safely reclaim it. This is exactly the kind of
infrastructure reasoning the self-healing agent demonstrates.

## Demo Script

### 1. Set the stage

> "Every node in an OpenShift cluster has a root filesystem that the kubelet
> uses for container images, pod ephemeral storage, and system logs. When this
> fills up, the kubelet starts evicting pods and the node becomes effectively
> unusable. Let's simulate a disk space exhaustion."

Show current node disk usage:

```bash
oc get nodes -o wide
oc adm top nodes
```

### 2. Trigger the failure

```bash
./demo/scenarios/03-node-disk-pressure/trigger.sh
```

> "We're writing a large file to the node's filesystem. In production this
> would be accumulated logs, ungarbage-collected images, or application data.
> The effect is the same -- the kubelet runs out of space."

This step takes 1-3 minutes for the large file write.

### 3. Watch the node condition change

```bash
oc get node <worker> -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

> "The kubelet now reports DiskPressure=True. It has already tainted the node
> to prevent new pods from scheduling here."

### 4. Watch the alert and workflow

Switch to **OpenShift Console** > Observe > Alerting.

> "NodeFilesystemSpaceFillingUp fires with labels identifying the exact device
> and mountpoint. This context is passed to the self-healing agent."

Open the workflow in **AAP** > Jobs:

- **Gather Diagnostics**: Show the node conditions with DiskPressure=True,
  the affected device and mountpoint.
- **AI Root Cause Analysis**: The AI identifies the disk pressure, suggests
  cleanup actions, and generates a targeted playbook.

### 5. Show the generated playbook

In **Gitea** > `remediation-playbooks`:

> "The playbook targets the specific node and filesystem. It uses variables
> for the node name so the same playbook can be reused if this happens on
> a different worker."

### 6. Show ServiceNow

> "The incident has the full timeline: diagnostics, root cause analysis, and
> the remediation playbook. An operator can see exactly what happened and
> what the agent recommends."

## Expected Outcome

- The node's `DiskPressure` condition is identified.
- The AI generates a playbook to clean up the filesystem.
- The node returns to normal scheduling after cleanup.
- ServiceNow tracks the full incident lifecycle.

## Cleanup

```bash
./demo/scenarios/03-node-disk-pressure/cleanup.sh
```

Or reset the full environment:

```bash
./setup/reset-demo.sh
```
