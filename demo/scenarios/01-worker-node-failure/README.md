# Scenario 1: Worker Node Failure

A worker node becomes unresponsive after its kubelet process stops. The node
transitions to `NotReady`, workloads are stranded, and the cluster loses
compute capacity.

## Infrastructure Layer

**Compute** -- affects the cluster's ability to schedule and run workloads on
the affected node.

## Alert

| Field | Value |
|-------|-------|
| Alert name | `KubeNodeNotReady` |
| Severity | `warning` |
| Key labels | `node=<affected-worker-node>` |
| Default `for` | 15 minutes (overridden to **1 minute** for the demo) |

## What Happens

1. The trigger script selects a non-GPU worker node that hosts the fewest
   critical self-healing components (AAP, RHOAI, Gitea).
2. The node is **cordoned** (marked unschedulable).
3. All pods are **drained** gracefully (DaemonSets excluded), so workloads
   reschedule to healthy nodes.
4. The kubelet process is **stopped** via `oc debug node/`.
5. Within ~60 seconds the node reports `Ready=False`, Prometheus fires
   `KubeNodeNotReady`, and Alertmanager sends the webhook to EDA.

## Why This Matters

Node failures are the most fundamental infrastructure incident in any
Kubernetes cluster. In production, they can be caused by hardware issues,
kernel panics, network partitions, or cloud provider outages. The ability to
detect, diagnose, and remediate a node failure automatically demonstrates the
core value proposition of the self-healing agent.

## Demo Script

### 1. Set the stage

> "We have a healthy OpenShift cluster with multiple worker nodes. Let's
> simulate a real infrastructure failure -- a worker node losing its kubelet
> process, which is the most common cause of node failures in production."

Show the current node status:

```bash
oc get nodes -o wide
```

### 2. Trigger the failure

```bash
./demo/scenarios/01-worker-node-failure/trigger.sh
```

The script will show which node it selected and ask for confirmation.
Walk through the three steps (cordon, drain, stop kubelet) as they execute.

### 3. Watch the alert fire

Switch to the **OpenShift Console** > Observe > Alerting.
Within ~1 minute, `KubeNodeNotReady` should appear as firing.

> "Prometheus detected that the node stopped sending heartbeats. The alert
> fires after just 1 minute in our demo configuration."

### 4. Watch EDA react

Switch to **AAP UI** > Event-Driven Ansible > Rule Audit.

> "Alertmanager sent a webhook to the EDA Controller. EDA matched the
> `KubeNodeNotReady` rule and triggered our self-healing workflow."

### 5. Walk through the workflow

Open the running workflow job in AAP > Jobs:

- **Step 1 -- Gather Diagnostics**: Show the job output with node conditions,
  pod list, and cluster events.
- **Step 2 -- Create ServiceNow Incident**: Switch to ServiceNow and show the
  new INC with diagnostics attached.
- **Step 3 -- Check Knowledge Base**: First time = no match (new incident type).
- **Step 4 -- AI Root Cause Analysis**: Show the RCA in ServiceNow work notes.
  Point out the AI identified the specific node and kubelet failure.
- **Step 5 -- Store Resolution**: The incident resolution is recorded for
  future automatic handling.

### 6. Show the generated playbook

Switch to **Gitea** > `remediation-playbooks` repo.

> "The AI generated a reusable Ansible playbook with parameterized variables.
> The same playbook works for any node -- the node name is passed as an
> extra variable when the Job Template is launched."

### 7. Show the AAP Job Template

Back in **AAP** > Templates, show the new `Remediate KubeNodeNotReady` template.

> "A human operator can review this template and launch it with one click.
> On subsequent occurrences, the agent will recognize this as a known issue
> and auto-execute the template."

### 8. (Optional) Demonstrate self-learning

Run the trigger again after cleanup. This time, Step 3 will find the existing
template in the knowledge base, and Step 4b will auto-launch it.

## Expected Outcome

- The node is recovered (kubelet restarted or machine replaced).
- ServiceNow incident is updated with full remediation details.
- A reusable Job Template exists in AAP for future incidents.

## Cleanup

```bash
./demo/scenarios/01-worker-node-failure/cleanup.sh
```

Or reset the full environment:

```bash
./setup/reset-demo.sh
```
