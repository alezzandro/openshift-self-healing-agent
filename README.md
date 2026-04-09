# OpenShift Self-Healing Agent

A self-healing automation agent for Red Hat OpenShift clusters, combining
**Red Hat Ansible Automation Platform 2.6**, **Red Hat OpenShift AI** (LlamaStack + vLLM),
**ServiceNow**, and **Gitea** into a closed-loop incident detection, diagnosis,
remediation, and learning system.

## How It Works

1. **Detect** -- OpenShift Prometheus fires an alert (node failure, operator degraded, etc.)
2. **React** -- Alertmanager webhook triggers AAP Event-Driven Ansible (EDA)
3. **Diagnose** -- AAP Workflow gathers cluster diagnostics and opens a ServiceNow incident
4. **Analyze** -- Ansible queries OpenShift Lightspeed for RAG context, then calls the LlamaStack `/v1/chat/completions` API; the AI model generates a Root Cause Analysis and a remediation playbook
5. **Remediate** -- The playbook is pushed to Gitea, synced to AAP, and a Job Template is created for human review or auto-execution
6. **Learn** -- Resolution is stored in a vector database; recurring issues are auto-remediated

## Architecture

```
Prometheus → Alertmanager → EDA Controller → AAP Workflow Template
                                                 ├─ gather-cluster-diagnostics
                                                 ├─ create-servicenow-incident
                                                 ├─ check-knowledge-base (vector search)
                                                 ├─ invoke-ai-agent
                                                 │    ├─ query OpenShift Lightspeed (RAG)
                                                 │    └─ call LlamaStack (Mistral Small 3.1 24B)
                                                 └─ store-incident-resolution
                                                        │
                                          ┌─────────────┼─────────────┐
                                          ▼             ▼             ▼
                                   AAP Controller   ServiceNow      Gitea
                                   (create JT)    (update INC)  (push playbooks)
```

All integrations (ServiceNow, Gitea, AAP Controller) are performed by Ansible
playbooks using direct REST API calls (`ansible.builtin.uri`).

See [docs/architecture.md](docs/architecture.md) for the full component diagram.

### RAG-Enhanced Playbook Generation via OpenShift Lightspeed

The AI agent uses **Retrieval-Augmented Generation (RAG)** to produce correct,
runnable Ansible playbooks. Before the LLM generates a remediation playbook, the
workflow queries **Red Hat OpenShift Lightspeed** -- the same AI assistant built
into the OpenShift Console -- for expert guidance on the detected alert.

Lightspeed ships with a pre-built FAISS vector index containing **1,728 OCP 4.21
documentation files** (18,000+ embedded chunks) using the `all-mpnet-base-v2`
sentence-transformer model. When the self-healing workflow fires, it sends the
alert details to the Lightspeed `/v1/query` endpoint. Lightspeed retrieves the
most relevant documentation, generates a contextual response, and returns both
the response text and a list of referenced documents (with links back to
`docs.openshift.com`). This context is then injected into the LlamaStack
prompt, giving the Mistral Small 3.1 24B model authoritative product documentation to
base its remediation playbook on.

This is a deliberately generic architecture. The RAG knowledge base is the
**entire OCP 4.21 documentation corpus** -- not a curated subset tailored to the
demo scenarios. This means the agent can reason about any OpenShift alert, not
just the four scenarios included in this demo. For customers evaluating the
approach, this demonstrates that the same architecture scales to their full
operational scope without per-alert knowledge engineering.

### Why Lightspeed Cluster Interaction Is Disabled

OpenShift Lightspeed supports a
[Cluster Interaction](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html-single/configure/index#about-cluster-interaction)
feature (`spec.ols.introspectionEnabled: true`) that deploys an MCP server
alongside the Lightspeed API. When enabled, Lightspeed can perform **live
read-only queries against the OpenShift API** (node status, pod conditions,
operator state, etc.) and fold that real-time cluster context into its answers.

This demo deliberately leaves that feature **disabled**. The reason comes from
the same model-size constraint discussed in the next section:

> *"The ability of OpenShift Lightspeed to choose and use a tool effectively is
> very sensitive to the large language model. In general, a larger model with
> more parameters performs better. When using a small model, you might notice
> poor performance in tool selection."*
> -- [Red Hat OpenShift Lightspeed 1.0 documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html-single/configure/index)

Mistral Small 3.1 24B (INT4 quantized) is a 24-billion-parameter model running
on a single NVIDIA L4. While substantially more capable than an 8B model, MCP
tool calling still requires the model to decide which tool to invoke, generate
correct JSON parameters, interpret structured responses, and weave them into
a coherent answer. Enabling introspection adds latency and token usage that
may not be justified when our architecture already collects cluster state
deterministically.

More importantly, our architecture already collects live cluster state
**deterministically**: the `gather-cluster-diagnostics.yml` playbook runs
`kubernetes.core` modules to fetch node conditions, pod events, operator
status, and Machine objects. That data is passed to the AI in the prompt.
Lightspeed's role is specifically the **documentation RAG layer** -- giving
the model authoritative OpenShift product knowledge it cannot get from the
diagnostics alone.

The separation is intentional:

| Concern | Handled by | Method |
|---------|-----------|--------|
| Live cluster state | Ansible (`gather-cluster-diagnostics.yml`) | Deterministic `kubernetes.core` module calls |
| Product documentation | OpenShift Lightspeed (RAG) | FAISS vector search over 18,000+ OCP 4.21 doc chunks |
| Reasoning + playbook generation | LlamaStack (Mistral Small 3.1 24B) | `/v1/chat/completions` with diagnostics + RAG context |

> **If the customer asks about Cluster Interaction:** Explain that the
> infrastructure is ready to enable it. Setting `introspectionEnabled: true`
> in the `OLSConfig` CR is a one-line change. When the organisation moves to
> a larger model (e.g., a 70B+ model, or a frontier model via API), Lightspeed
> would provide both documentation **and** live cluster context in a single
> call, eliminating the need for the separate diagnostics playbook. This is a
> natural upgrade path, not a limitation.

### Gen AI Playground (Technology Preview)

The setup enables the **Gen AI Playground** feature introduced in Red Hat
OpenShift AI 3.3. This provides an interactive chat interface in the OpenShift
AI dashboard where you can directly converse with the deployed Mistral Small
3.1 24B model, test prompt engineering with RAG documents, and interact with
the ServiceNow and Git MCP servers -- all without writing any code.

The setup script (`03-configure-rhoai.sh`) configures three things:

1. **`genAiStudio: true`** in the `OdhDashboardConfig` -- unlocks the
   *Gen AI Studio* menu item in the OpenShift AI navigation sidebar.
2. **`opendatahub.io/genai-asset: "true"` label** on the InferenceService --
   registers the model as an *AI asset endpoint*, making it selectable in the
   Playground UI.
3. **`gen-ai-aa-mcp-servers` ConfigMap** in `redhat-ods-applications` -- makes
   the ServiceNow and Git MCP servers available in the Playground's MCP section
   so you can demonstrate tool-calling capabilities interactively.

To use the Playground:

1. Navigate to **Gen AI Studio > AI asset endpoints** in the OpenShift AI
   dashboard.
2. Select the `rhoai-project` project.
3. Locate **Mistral-Small-3.1-24B-Instruct (INT4)** and click
   **Add to playground**.
4. In the Playground, optionally expand **MCP servers** and enable the
   ServiceNow or Git server to demonstrate tool calling.

> **Note:** The Gen AI Playground is a Technology Preview feature in RHOAI 3.3.
> It is stateless -- browser refresh clears chat history. For the demo, it
> serves as a powerful way to show the customer that the same AI model powering
> the self-healing workflow is also accessible as a general-purpose assistant
> through a familiar chat interface.

For full documentation, see
[Experimenting with models in the gen AI playground](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html-single/experimenting_with_models_in_the_gen_ai_playground/index)
(Red Hat OpenShift AI Self-Managed 3.3).

### Why Ansible Orchestration Instead of MCP Tool Calls

You will notice that the setup deploys **ServiceNow MCP** and **Git MCP** server
pods in the `self-healing-agent` namespace, yet the self-healing workflow does
not route through them. This is a deliberate design choice worth understanding
before you present the demo.

The original architecture had the AI model (running on a single
NVIDIA L4 GPU) driving the entire remediation loop through
[MCP tool calls](https://modelcontextprotocol.io/): the model would decide
*when* to create a ServiceNow incident, *when* to push a playbook to Git, and
*when* to create an AAP Job Template. In practice, smaller parameter-count
models struggle with reliable multi-tool orchestration -- they may call tools in
the wrong order, pass incorrect parameters, or skip steps entirely. For a
customer-facing demo that must be repeatable and explainable, that level of
non-determinism is a liability.

The current architecture splits responsibilities along a clear boundary:

- **AI handles analysis** -- The model receives cluster diagnostics and produces
  a Root Cause Analysis and a remediation Ansible playbook. This is where
  generative AI excels: reasoning over unstructured data and writing code.
- **Ansible handles orchestration** -- The AAP workflow playbooks drive every
  integration (ServiceNow, Gitea, AAP Controller) using explicit REST API calls.
  Each step is deterministic, observable in the AAP job output, and auditable.

This hybrid approach is actually a stronger story for the customer. It shows
that AI augments the automation platform rather than replacing it, and that
the organisation retains full control over what actions are taken and when.
The AI proposes; Ansible executes. That separation of concerns maps directly
to how real enterprises adopt AI in operations -- they want intelligence in
the analysis layer and governance in the execution layer.

> **If the customer asks about MCP:** The MCP servers are deployed and
> functional. They can be demonstrated independently to show the MCP protocol
> in action. If you later move to a larger model (e.g., a 70B+ model via
> multi-GPU or API) with stronger tool-use capabilities, the MCP integration
> path is ready to activate without rebuilding the infrastructure.

## Demo Scenarios

All scenarios target **cluster infrastructure**, not user workloads:

| # | Scenario | Layer | Alert |
|---|----------|-------|-------|
| 1 | Worker Node Failure | Compute | `KubeNodeNotReady` |
| 2 | Authentication Operator Degraded | Cluster Authentication | `ClusterOperatorDegraded{name="authentication"}` |
| 3 | Node Disk Pressure | Node Resources | `NodeFilesystemSpaceFillingUp` |
| 4 | MachineConfigPool Degraded | Node Configuration | `MCPDegraded` |

Each scenario has its own `README.md` with a full presenter script and talking points.
See `demo/scenarios/<scenario>/README.md`.

## Prerequisites

- OpenShift 4.21 cluster on AWS (see [Cluster Sizing](#cluster-sizing) below)
- `oc` CLI authenticated as `cluster-admin`
- `podman` for building the custom Execution Environment
- `ansible-builder` installed locally (`pip install ansible-builder`)
- A [ServiceNow Developer Instance](docs/servicenow-developer-instance.md)
- Red Hat Ansible Automation Platform subscription manifest (see [Private Files Setup](#private-files-setup) below)

## Cluster Sizing

| Node Role | Instance Type | Count | Specs |
|-----------|--------------|-------|-------|
| Control plane | m5a.2xlarge | 3 | 8 vCPU, 32 GB RAM |
| Worker (general) | m5a.2xlarge | 4 | 8 vCPU, 32 GB RAM |
| Worker (GPU) | g6.2xlarge | 1 | 8 vCPU, 32 GB RAM, 1x NVIDIA L4 24 GB |

> **Why 4 general workers?** The worker-node-failure demo scenario cordons and
> drains a worker node before stopping the kubelet. The extra node ensures that
> AAP, OpenShift AI, and other critical self-healing components can be safely
> rescheduled without resource starvation during the demo.

Storage class required: `gp3-csi` (RWO). The setup scripts automatically patch
AAP Hub to use `ReadWriteOnce` storage, so no RWX storage class is needed.

## Private Files Setup

The `ansible/private/` directory (git-ignored) holds credentials and license files that
must be placed manually before running the setup scripts.

| File | Required | Description |
|------|----------|-------------|
| `*.zip` (manifest) | **Yes** | AAP subscription manifest -- uploaded automatically by `07-configure-aap.sh` |
| `rh-enterprise-ansible-galaxy-token.txt` | **Yes** | Automation Hub API token for certified collections |
| `RH-AutomationHub-instructions.txt` | No | Reference notes for Automation Hub URLs |

### Creating an AAP Subscription Manifest

1. Log in to the [Red Hat Subscription Allocations](https://access.redhat.com/management/subscription_allocations) page.
2. Click **Create New subscription allocation**.
3. Set the **Name** (e.g., `self-healing-demo`) and **Type** to **Satellite 6.15** (this is used for manifest export even though we are not using Satellite).
4. On the allocation detail page, go to the **Subscriptions** tab and attach an
   **Ansible Automation Platform** entitlement (a 60-day trial works).
5. Click **Export Manifest** to download the `.zip` file.
6. Place the downloaded `.zip` in `ansible/private/`:
   ```bash
   cp ~/Downloads/manifest_*.zip ansible/private/
   ```

The `07-configure-aap.sh` script will automatically detect and upload the manifest
to the AAP Controller API. If no manifest is found, you can also upload it manually
through the AAP web UI under **Settings > Subscription**.

### Obtaining an Automation Hub Token

1. Log in to [console.redhat.com/ansible/automation-hub/token](https://console.redhat.com/ansible/automation-hub/token).
2. Click **Load token** and copy the value.
3. Save it to `ansible/private/rh-enterprise-ansible-galaxy-token.txt`:
   ```bash
   echo "your-token-here" > ansible/private/rh-enterprise-ansible-galaxy-token.txt
   ```

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/<org>/openshift-self-healing-agent.git
cd openshift-self-healing-agent

# 2. Run the full setup (interactive -- prompts for ServiceNow credentials)
./setup/full-setup.sh

# 3. Trigger a demo scenario
./demo/scenarios/01-worker-node-failure/trigger.sh

# 4. Watch the workflow in AAP UI and ServiceNow

# 5. Clean up the scenario
./demo/scenarios/01-worker-node-failure/cleanup.sh

# 6. Reset the full environment for the next demo run
./setup/reset-demo.sh
```

## Setup Scripts

Run individually or use `full-setup.sh` for the complete installation:

| Script | Purpose |
|--------|---------|
| `00-prereqs.sh` | Verify cluster access, tools, storage classes |
| `01-install-operators.sh` | Install AAP 2.6, RHOAI, Lightspeed, NFD, GPU Operator |
| `02-configure-gpu.sh` | Configure GPU node discovery and drivers |
| `03-configure-rhoai.sh` | Deploy vLLM, LlamaStack, Lightspeed RAG integration |
| `04-deploy-gitea.sh` | Deploy Gitea git server in-cluster |
| `05-configure-servicenow.sh` | Create SNOW users, roles, clean incidents |
| `06-deploy-mcp-servers.sh` | Deploy ServiceNow and Git MCP servers |
| `07-configure-aap.sh` | Build EE image, configure AAP credentials, templates, EDA |
| `08-configure-monitoring.sh` | Deploy alert rules and Alertmanager routing |
| `show-credentials.sh` | Display URLs and credentials for all services |
| **`health-check.sh`** | **Verify all components after cluster restart** |
| **`reset-demo.sh`** | **Reset to a clean state between demo runs** |

### Morning Health Check (After Cluster Restart)

If you stop the lab overnight, run the health check when the cluster comes back
up to verify every component is operational before starting a demo:

```bash
./setup/health-check.sh
```

The script validates 29 checks across 10 categories:

1. **Cluster** -- API server, node readiness
2. **Operators** -- CSV status for AAP, RHOAI, Lightspeed, NFD, GPU
3. **AAP** -- Controller API, EDA activation, webhook service
4. **OpenShift AI** -- DataScienceCluster, InferenceService, LlamaStack
5. **Lightspeed** -- OLSConfig, API readiness, SA token, NetworkPolicy
6. **Gitea** -- Web UI, repo accessibility
7. **ServiceNow** -- Instance reachability (dev instances hibernate after inactivity)
8. **Monitoring** -- PrometheusRule, Alertmanager webhook config
9. **NetworkPolicies** -- AAP-to-LlamaStack and AAP-to-Lightspeed
10. **End-to-end connectivity** -- Cross-namespace calls from the AAP namespace

The exit code is `0` when all checks pass, making it safe to use in scripts.
Common post-restart issues include the GPU node needing extra time to
initialize (InferenceService not ready), ServiceNow dev instances needing a
manual wake-up, and EDA activations occasionally stopping during shutdown.

### Resetting Between Demo Runs

Before each new demo session, run the reset script to clean up all artifacts
from the previous run **without** uninstalling any platform component:

```bash
./setup/reset-demo.sh
```

This cleans:
- OpenShift: uncordons nodes, restarts kubelets on NotReady workers, removes broken identity provider
  from OAuth config, removes disk-fill files from workers, deletes conflicting MachineConfigs
- AAP: deletes all Workflow Jobs, standalone Jobs, and `Remediate *` Job Templates
- AAP EDA: restarts the rulebook activation to reset the 3-hour throttle window
- Gitea: removes AI-generated remediation playbooks (`remediate-*.yml`)
- ServiceNow: deletes all incidents
- Monitoring: re-applies Alertmanager config and refreshes protected-node labels

## Project Structure

```
├── docs/                        # Documentation
├── setup/                       # Setup, installation, and reset scripts
├── manifests/                   # Kubernetes/OpenShift manifests
│   ├── operators/               # Operator Subscriptions
│   ├── rhoai/                   # OpenShift AI + LlamaStack
│   ├── gitea/                   # Gitea deployment
│   ├── mcp-servers/             # MCP server deployments
│   └── monitoring/              # PrometheusRule & Alertmanager config
├── ansible/                     # Ansible content
│   ├── execution-environment/   # Custom EE definition
│   ├── playbooks/               # All workflow playbooks
│   ├── roles/                   # Shared roles (llamastack_common, servicenow_setup)
│   ├── templates/               # Jinja2 system prompts for AI
│   ├── rag-docs/                # (Legacy) curated docs — replaced by Lightspeed RAG
│   ├── rulebooks/               # EDA rulebooks
│   ├── inventory/               # Ansible inventory (localhost)
│   └── private/                 # Credentials & manifest (git-ignored)
├── mcp-servers/                 # MCP server Containerfiles
│   ├── servicenow-mcp/
│   └── git-mcp/
└── demo/                        # Demo scenario scripts
    └── scenarios/
```

## Documentation

- [Architecture](docs/architecture.md) -- Full component diagram and data flow
- [ServiceNow Developer Instance](docs/servicenow-developer-instance.md) -- Setup guide
- [Demo Walkthrough](docs/demo-walkthrough.md) -- Scripted demo with talking points

## Products Featured

- **Red Hat OpenShift Container Platform** 4.21
- **Red Hat Ansible Automation Platform** 2.6 (Controller, EDA, Hub)
- **Red Hat OpenShift AI** 3.x (LlamaStack, vLLM, KServe)
- **Red Hat OpenShift Lightspeed** (RAG over OCP 4.21 product documentation)
- **NVIDIA GPU Operator** (L4 acceleration)
- **ServiceNow** ITSM (Developer Instance)
- **Gitea** (in-cluster Git server)

## License

Apache License 2.0 -- see [LICENSE](LICENSE).
