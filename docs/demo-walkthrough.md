# Demo Walkthrough

## Before You Begin

- Verify the full setup completed: `./setup/health-check.sh` (GitOps checks require `./setup/09-configure-gitops.sh`)
- Open the AAP Controller UI, ServiceNow, Argo CD, and Gitea (`./setup/show-credentials.sh`)
- Have a terminal ready for trigger commands
- Pick a track: infrastructure (`demo/infrastructure/`) or GitOps CNF delivery (`demo/gitops/`)

## Scenario 1: Worker Node Failure

### Narrative

> "A worker node in our OpenShift cluster has become unresponsive. The kubelet
> process has stopped, and the node is no longer sending heartbeats. Let's see
> how the self-healing agent detects and resolves this automatically."

### Steps

1. **Trigger the failure:**
   ```bash
   ./demo/infrastructure/scenarios/01-worker-node-failure/trigger.sh
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
   ./demo/infrastructure/scenarios/01-worker-node-failure/cleanup.sh
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

1. **Trigger:** `./demo/infrastructure/scenarios/02-authentication-operator-degraded/trigger.sh`
2. The script waits ~90 seconds for the operator to transition to `Degraded=True`
3. Wait for `ClusterOperatorDegraded{name="authentication"}` alert (~1 min after degradation)
4. Watch the workflow in AAP -- point out the diagnostics step collecting the
   OAuth configuration showing the broken identity provider reference
5. Show the RCA in ServiceNow identifying the missing Secret as root cause
6. Show the AI-generated playbook in Gitea that removes the broken IDP entry
7. **Cleanup:** `./demo/infrastructure/scenarios/02-authentication-operator-degraded/cleanup.sh`

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

1. **Trigger:** `./demo/infrastructure/scenarios/03-node-disk-pressure/trigger.sh`
2. Wait for `NodeFilesystemSpaceFillingUp` alert (~1 min)
3. Watch the workflow -- show the diagnostics identifying the DiskPressure node
   condition and the affected filesystem
4. Show the RCA in ServiceNow explaining the disk usage pattern
5. Show the generated playbook targeting the specific node and filesystem
6. **Cleanup:** `./demo/infrastructure/scenarios/03-node-disk-pressure/cleanup.sh`

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

1. **Trigger:** `./demo/infrastructure/scenarios/04-mcp-degraded/trigger.sh`
2. Wait for `MCPDegraded` alert (~1 min)
3. Watch the workflow -- show the diagnostics collecting MCP conditions and the
   list of MachineConfigs
4. Show the RCA in ServiceNow identifying the conflicting MachineConfig
5. Show the playbook that deletes the conflicting MC to unblock the pool
6. **Cleanup:** `./demo/infrastructure/scenarios/04-mcp-degraded/cleanup.sh`

### Key Talking Point

> MachineConfig conflicts are a real Day-2 operations challenge. The MCO provides
> no self-healing for conflicting configs -- it simply reports Degraded and waits.
> The AI agent identifies which specific MC causes the conflict, something that
> requires understanding the MCO rendering pipeline.

## GitOps Track: ImagePullBackOff (bad tag)

Presenter script: `demo/gitops/README.md` and
`demo/gitops/scenarios/01-imagepullbackoff-bad-tag/README.md`.

### Narrative

> "A CNF-like app is delivered by Red Hat OpenShift GitOps. Someone committed a
> container tag that does not exist in the registry. Argo CD synced it faithfully
> — Git is correct from Argo's point of view — and the pods are stuck in
> ImagePullBackOff. The agent must fix Git, not fight Argo with a live patch."

### Steps

1. **Trigger:** `./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/trigger.sh`
2. Confirm `ImagePullBackOff` in namespace `cnf-gitops-demo` and in the Argo CD
   UI (Application `cnf-sample`, failed pods). Gitea `cnf-sample` shows
   `registry.access.redhat.com/ubi9/httpd-24:demo-bad-tag`.
3. Wait for `DemoCNFImagePullBackOff` (~1 minute `for:`; ~2–3 minutes from
   trigger). Observe > Alerting, then AAP EDA Rule Audit and Jobs.
4. Show ServiceNow RCA: Git source of truth, Argo Application `cnf-sample`,
   approve the git-fix Job Template — do not `oc set image`.
5. **First run:** launch `Remediate DemoCNFImagePullBackOff` in AAP. Gitea
   commit restores `registry.access.redhat.com/ubi9/httpd-24:latest`; Argo CD
   becomes Healthy; pods Running.
6. **Second run (learning loop):** do not wipe the knowledge base.
   ```bash
   ./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/reset-eda.sh
   ./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/trigger.sh
   ```
   KB match auto-launches the same JT; Git + Argo heal without a second approval.
7. **Cleanup:** `./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/cleanup.sh`

### Key Talking Point

> Remediation is a commit to Gitea. OpenShift GitOps reconciles the cluster.
> The first incident is human-approved; the second is automatic because the
> golden git-fix Job Template is already in the knowledge base.

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
- **GitOps-correct**: CNF ImagePullBackOff is fixed in Git; Argo CD syncs. Live
  patches would be reverted by self-heal and would hide the source of truth
- **Reusable playbooks**: AI-generated playbooks use variables instead of hardcoded
  values, making them reusable for future incidents of the same type
- **Red Hat stack**: Built entirely on supported Red Hat products with certified
  Ansible collections
