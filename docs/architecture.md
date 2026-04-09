# Architecture

## Component Diagram

```
┌──────────────────────────── OpenShift 4.21 Cluster ────────────────────────────┐
│                                                                                │
│  ┌─── Cluster Monitoring ───┐    ┌────────── AAP 2.6 ──────────┐              │
│  │  Prometheus              │    │  EDA Controller              │              │
│  │  Alertmanager ───────────┼───►│  Automation Controller       │              │
│  │  PrometheusRule overrides│    │  Custom Execution Env        │              │
│  └──────────────────────────┘    └──────────┬───────────────────┘              │
│                                             │                                  │
│                                             ▼  Workflow runs playbooks         │
│  ┌─── OpenShift AI ────────┐    ┌───────────────────────────────────┐          │
│  │  vLLM ServingRuntime    │◄───│  Ansible playbooks                │          │
│  │  LlamaStack Server     │    │  (ansible.builtin.uri calls)      │          │
│  │  PostgreSQL + pgvector  │    │                                   │          │
│  └─────────────────────────┘    │                                   │          │
│  ┌─── OpenShift Lightspeed ─┐   │                                   │          │
│  │  OLS API (RAG)           │◄──│  (query for OCP 4.21 docs)       │          │
│  │  FAISS vector DB         │   │                                   │          │
│  │  all-mpnet-base-v2       │   │   ┌───────┬─────────┬─────────┐  │          │
│  └──────────────────────────┘   │   │       │         │         │  │          │
│                                 │   ▼       ▼         ▼         │  │          │
│  ┌─────────────────────┐        │  AAP    Gitea    ServiceNow   │  │          │
│  │  Gitea Server       │◄───────│  API    API      REST API     │  │          │
│  │  (playbook repo)    │        │         (push)   (impersonate) │  │          │
│  └─────────────────────┘        └───────────────────────────────────┘          │
│                                                     │                          │
└─────────────────────────────────────────────────────┼──────────────────────────┘
                                                      │
                                                      ▼
                                             ServiceNow Dev Instance
                                             (svc-aap-automation /
                                              svc-ai-agent via impersonation)
```

## Data Flow

### First-time incident (no knowledge base match)

1. Prometheus detects anomaly, fires alert via configured `PrometheusRule`
2. Alertmanager routes alert to EDA Controller webhook endpoint
3. EDA rulebook matches the alert and triggers the AAP Workflow Template
4. **Step 1**: `gather-cluster-diagnostics.yml` collects node status, events,
   pod states, and operator conditions using `kubernetes.core` modules
5. **Step 2**: `create-servicenow-incident.yml` opens a new incident via the
   ServiceNow REST API (using admin impersonation as `svc-aap-automation`),
   attaches human-readable diagnostics as work notes, and uploads raw
   diagnostics JSON as an attachment
6. **Step 3**: `check-knowledge-base.yml` queries LlamaStack vector store for
   similar past incidents -- no match found
7. **Step 4a**: `invoke-ai-new-incident.yml` first queries **OpenShift
   Lightspeed** (`/v1/query`) for expert remediation guidance based on the
   full OCP 4.21 product documentation (18,000+ document chunks), then calls
   the LlamaStack `/v1/chat/completions` API with the system prompt,
   Lightspeed RAG context, and diagnostics; the playbook then:
   - Parses the AI response into a Root Cause Analysis and a remediation playbook
   - Updates the ServiceNow incident with the RCA (impersonating `svc-ai-agent`)
   - Pushes the playbook to Gitea via the Gitea REST API
   - Syncs the AAP project and creates a Job Template via the AAP Controller API
   - Updates ServiceNow with remediation details and next steps
8. **Step 5**: `store-incident-resolution.yml` records the incident + resolution
   for future matching

### Recurring incident (knowledge base match found)

Steps 1-3 are identical, then:

7. **Step 4b**: `invoke-ai-known-incident.yml` calls LlamaStack with the matched
   RCA and existing Job Template ID; the playbook then:
   - Updates ServiceNow with the known RCA (impersonating `svc-ai-agent`)
   - Triggers the existing Job Template for automatic remediation
   - Updates ServiceNow with auto-remediation status
8. **Step 5**: records the new incident occurrence

## Component Details

| Component | Namespace | Resources |
|-----------|-----------|-----------|
| AAP Controller | `aap` | Deployment, Route, PostgreSQL |
| EDA Controller | `aap` | Deployment, Route |
| Automation Hub | `aap` | Deployment, PVC (RWO, patched by setup) |
| vLLM InferenceService | `rhoai-project` | ServingRuntime, InferenceService, GPU pod |
| LlamaStack Server | `rhoai-project` | LlamaStackDistribution, PostgreSQL |
| OpenShift Lightspeed | `openshift-lightspeed` | Deployment, PostgreSQL, FAISS vector DB |
| ServiceNow MCP | `self-healing-agent` | Deployment, Service |
| Git MCP | `self-healing-agent` | Deployment, Service |
| Gitea | `gitea` | StatefulSet, Service, Route, PVC |
| Monitoring overrides | `openshift-monitoring` | PrometheusRule, Alertmanager Secret |

## Network Topology

- Alertmanager → EDA: internal Service (`http://cluster-alert-handler.aap.svc:5000/endpoint`)
- AAP playbooks → Lightspeed: internal Service (`https://lightspeed-app-server.openshift-lightspeed.svc:8443`) with SA bearer token
- AAP playbooks → LlamaStack: internal Service (`http://self-healing-agent-service.rhoai-project.svc.cluster.local:8321`)
- LlamaStack → vLLM: internal Service (KServe predictor)
- AAP playbooks → ServiceNow: external HTTPS to developer instance (admin impersonation)
- AAP playbooks → Gitea: internal Route / Service (REST API)
- AAP playbooks → AAP Controller: loopback to controller API (job templates, project sync)
- Gitea: exposed via OpenShift Route for AAP SCM credential
