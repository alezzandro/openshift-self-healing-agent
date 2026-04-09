# Scenario 4: MachineConfigPool Degraded

A conflicting MachineConfig is applied to the worker pool. The Machine Config
Operator (MCO) cannot render the desired configuration, and the worker
MachineConfigPool is stuck in a `Degraded` state. No nodes reboot -- the render
fails before any drain or reboot is scheduled.

## Infrastructure Layer

**Node Configuration** -- affects the MCO's ability to apply and reconcile
node-level configuration (kernel args, systemd units, file content, etc.)
across the worker pool.

## Alert

| Field | Value |
|-------|-------|
| Alert name | `MCPDegraded` |
| Severity | `warning` |
| Key labels | `name=worker` |
| Default `for` | 30 minutes (overridden to **1 minute** for the demo) |

## What Happens

1. The trigger script creates a MachineConfig (`self-healing-demo-conflict`)
   that uses the Ignition `append` directive on a file. The MCO explicitly
   rejects `append` operations at render time because it cannot reconcile
   appended content across MachineConfig layers.
2. The MCO render controller detects the unsupported `append` entry and
   immediately marks the worker MCP as `RenderDegraded=True`.
3. The worker MCP transitions to `Degraded=True` / `RenderDegraded=True`.
4. **No nodes drain or reboot** -- the MCO aborts before scheduling any
   node updates because the render step itself failed.
5. Prometheus fires `MCPDegraded` and Alertmanager sends the webhook to EDA.

## Why This Matters

MachineConfig issues are a real and common Day-2 operations problem:

- Multiple teams apply MCs that target the same file path
- A third-party operator creates an MC that conflicts with a custom one
- A copy-paste error introduces an unsupported Ignition directive (e.g. `append`)

The MCO has **no self-healing capability** for config conflicts. It simply
marks the pool as Degraded and waits indefinitely for human intervention.
Finding which specific MC causes the conflict requires understanding the MCO
rendering pipeline -- exactly the kind of reasoning the AI agent can perform
by analyzing the MCP conditions and the list of applied MachineConfigs.

## Demo Script

### 1. Set the stage

> "The Machine Config Operator manages node-level configuration for every node
> in a pool. When a conflicting configuration is applied -- for example, two
> MachineConfigs writing different content to the same file -- the MCO cannot
> decide which one wins. It marks the pool as Degraded and stops all updates."

Show the current MCP status:

```bash
oc get mcp
oc get mc --sort-by=.metadata.creationTimestamp | tail -10
```

### 2. Trigger the failure

```bash
./demo/scenarios/04-mcp-degraded/trigger.sh
```

> "We applied a MachineConfig that uses an Ignition `append` directive. The
> MCO cannot reconcile `append` operations across configuration layers, so it
> immediately rejects the render."

### 3. Watch the MCP status

```bash
oc get mcp worker -o yaml | grep -A5 conditions
```

> "The worker pool is now Degraded. Notice that no nodes are draining or
> rebooting -- the render failed before any node-level action was taken.
> This is safe but the pool is completely stuck."

### 4. Watch the alert and workflow

Switch to **OpenShift Console** > Observe > Alerting.

> "MCPDegraded fires, identifying the worker pool. The self-healing agent
> receives this through EDA."

Open the workflow in **AAP** > Jobs:

- **Gather Diagnostics**: Show the MCP conditions (`RenderDegraded=True`)
  and the list of MachineConfigs.
- **AI Root Cause Analysis**: The AI cross-references the MCP error message
  with the MC list and identifies `self-healing-demo-conflict` as the
  offending config.

### 5. Show the generated playbook

In **Gitea** > `remediation-playbooks`:

> "The playbook identifies and deletes the conflicting MachineConfig. The
> MC name is parameterized as a variable, so the same playbook works for
> any future MachineConfig conflict -- just pass the MC name as an extra
> variable."

### 6. Emphasize the MCO gap

> "This is a scenario where OpenShift has no built-in self-healing. The MCO
> will stay Degraded indefinitely until someone manually identifies and removes
> the conflicting MC. Our agent fills that gap by using AI to analyze the
> render failure and generate a targeted fix."

## Expected Outcome

- The worker MCP is identified as Degraded due to a render failure.
- The AI identifies the specific offending MachineConfig by name.
- A remediation playbook to delete the conflicting MC is generated.
- No nodes were rebooted or disrupted during the scenario.
- ServiceNow tracks the full incident lifecycle.

## Cleanup

```bash
./demo/scenarios/04-mcp-degraded/cleanup.sh
```

Or reset the full environment:

```bash
./setup/reset-demo.sh
```
