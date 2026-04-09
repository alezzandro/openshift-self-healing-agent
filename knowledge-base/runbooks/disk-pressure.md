# Runbook: NodeFilesystemSpaceFillingUp / Disk Pressure

## Alert
NodeFilesystemSpaceFillingUp fires when a node's filesystem usage exceeds
a critical threshold. The node may receive a disk-pressure taint.

## Root Cause
Common space consumers on OpenShift worker nodes include:
- Container image cache (unused layers)
- Completed/failed pods left behind
- Old log files under /var/log
- Large core dumps or temp files under /var/tmp

## Approved Remediation
1. Identify the mount point under pressure from the alert details.
2. Clean up known space consumers:
   - Prune unused container images
   - Delete completed pods
   - Remove old log files
3. If the node has a `node.kubernetes.io/disk-pressure` taint, it should
   clear automatically once sufficient space is freed.
4. Verify the taint is removed and the node returns to Ready state.

## Variables
- `target_node`: the name of the node experiencing disk pressure (required)
- `pressure_mount`: the filesystem mount point (default '/')
