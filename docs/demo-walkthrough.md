# Demo Walkthrough

## Before You Begin

- Verify the full setup completed: `./setup/00-prereqs.sh`
- Open the AAP Controller UI in a browser
- Open the ServiceNow Developer Instance in another tab
- Have a terminal ready for trigger commands

## Scenario 1: Worker Node Failure

### Narrative

> "A worker node in our OpenShift cluster has become unresponsive. The kubelet
> process has stopped, and the node is no longer sending heartbeats. Let's see
> how the self-healing agent detects and resolves this automatically."

### Steps

1. **Trigger the failure:**
   ```bash
   ./demo/scenarios/01-worker-node-failure/trigger.sh
   ```

2. **Watch Prometheus** (optional): In the OpenShift console, navigate to
   Observe > Alerting. Within ~1 minute, `KubeNodeNotReady` should fire.

3. **Watch EDA**: In the AAP UI, go to Event-Driven Ansible > Rule Audit.
   The alert should appear and trigger the workflow.

4. **Watch the Workflow**: In AAP > Jobs, open the running workflow. Walk through
   each step:
   - Step 1: Diagnostics gathered (show the node conditions in the job output)
   - Step 2: ServiceNow incident created (switch to SNOW, show the new INC)
   - Step 3: Knowledge base checked (first time = no match)
   - Step 4a: AI agent invoked (show the RCA in SNOW work notes)
   - Step 5: Resolution stored for future matching

5. **Show ServiceNow**: The incident now has:
   - Root Cause Analysis attached
   - A new Job Template ready for review
   - Instructions for the operator

6. **Show the generated playbook**: In Gitea, navigate to the `remediation-playbooks`
   repo and show the AI-generated playbook.

7. **Clean up:**
   ```bash
   ./demo/scenarios/01-worker-node-failure/cleanup.sh
   ```

### Second Run (Self-Learning Demo)

1. **Trigger the same failure again** to demonstrate the learning loop
2. This time, Step 3 finds a match in the knowledge base
3. Step 4b auto-executes the previously created Job Template
4. ServiceNow is updated showing automatic remediation
5. The node recovers without human intervention

## Scenario 2: Authentication Operator Degraded

### Narrative

> "The OpenShift authentication operator manages the cluster's OAuth server and
> identity providers. Someone has added an HTPasswd identity provider that
> references a Secret that doesn't exist -- perhaps a typo during an SSO
> integration or a miscopy from a staging environment. The operator degrades
> because it cannot validate the configuration. Let's see the agent detect,
> diagnose, and remediate this."

### Steps

1. **Trigger:** `./demo/scenarios/02-authentication-operator-degraded/trigger.sh`
2. The script waits ~90 seconds for the operator to transition to `Degraded=True`
3. Wait for `ClusterOperatorDegraded{name="authentication"}` alert (~1 min after degradation)
4. Watch the workflow in AAP -- point out the diagnostics step collecting the
   OAuth configuration showing the broken identity provider reference
5. Show the RCA in ServiceNow identifying the missing Secret as root cause
6. Show the AI-generated playbook in Gitea that removes the broken IDP entry
7. **Cleanup:** `./demo/scenarios/02-authentication-operator-degraded/cleanup.sh`

### Key Talking Point

> Existing logins, sessions, and the OAuth server pods are completely unaffected.
> The operator reports Degraded because it cannot reconcile the new configuration,
> but the running OAuth server continues serving authentication requests using the
> valid identity providers. This is a realistic Day-2 scenario where an IDP
> misconfiguration during SSO integration or certificate rotation degrades the
> authentication operator -- detectable only through infrastructure monitoring.

## Scenario 3: Node Disk Pressure

### Narrative

> "A worker node's filesystem is filling up -- accumulated container images, logs,
> or ephemeral data has pushed usage past the critical threshold. The kubelet is
> evicting pods and the node is tainted NoSchedule. Let's watch the agent identify
> the disk pressure and generate a cleanup playbook."

### Steps

1. **Trigger:** `./demo/scenarios/03-node-disk-pressure/trigger.sh`
2. Wait for `NodeFilesystemSpaceFillingUp` alert (~1 min)
3. Watch the workflow -- show the diagnostics identifying the DiskPressure node
   condition and the affected filesystem
4. Show the RCA in ServiceNow explaining the disk usage pattern
5. Show the generated playbook targeting the specific node and filesystem
6. **Cleanup:** `./demo/scenarios/03-node-disk-pressure/cleanup.sh`

### Key Talking Point

> Disk pressure is one of the most common infrastructure issues in production
> clusters. It requires node-specific diagnosis (which filesystem, what is
> consuming space) that application-level monitoring cannot provide. The AI
> produces a node-targeted playbook with the correct filesystem paths.

## Scenario 4: MachineConfigPool Degraded

### Narrative

> "A conflicting MachineConfig has been applied to the worker pool. The Machine
> Config Operator cannot render the desired configuration, and the worker pool
> is stuck in a Degraded state. No nodes reboot because the render fails before
> any drain or reboot is scheduled. Let's see the agent identify the conflicting
> MC and generate a remediation."

### Steps

1. **Trigger:** `./demo/scenarios/04-mcp-degraded/trigger.sh`
2. Wait for `MCPDegraded` alert (~1 min)
3. Watch the workflow -- show the diagnostics collecting MCP conditions and the
   list of MachineConfigs
4. Show the RCA in ServiceNow identifying the conflicting MachineConfig
5. Show the playbook that deletes the conflicting MC to unblock the pool
6. **Cleanup:** `./demo/scenarios/04-mcp-degraded/cleanup.sh`

### Key Talking Point

> MachineConfig conflicts are a real Day-2 operations challenge. The MCO provides
> no self-healing for conflicting configs -- it simply reports Degraded and waits.
> The AI agent identifies which specific MC causes the conflict, something that
> requires understanding the MCO rendering pipeline.

## Talking Points

- **Closed loop**: From detection to diagnosis to remediation, no human needed
- **Self-learning**: The knowledge base remembers past incidents; recurring issues
  are resolved faster with automatic execution
- **Audit trail**: Every action is tracked in ServiceNow and AAP job logs
- **Human-in-the-loop**: First occurrence requires operator review; only proven
  remediations are auto-executed
- **Infrastructure-grade**: Handles diverse cluster infrastructure layers -- compute
  (nodes), cluster authentication (OAuth/IDP), node resources (disk), and node
  configuration management (MachineConfigPool)
- **Reusable playbooks**: AI-generated playbooks use variables instead of hardcoded
  values, making them reusable for future incidents of the same type
- **Red Hat stack**: Built entirely on supported Red Hat products with certified
  Ansible collections
