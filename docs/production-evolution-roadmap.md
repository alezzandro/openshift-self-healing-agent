# Production Evolution Roadmap

**From Demo to Autonomous Self-Healing Platform**

This document describes the architectural evolution required to take the
OpenShift Self-Healing Agent from a four-scenario demo to a production-grade,
general-purpose autonomous remediation platform. It is not a step-by-step
implementation guide; it is a reference architecture and decision framework
for engineering and product teams evaluating the next phase.

Throughout this document, "current state" refers to the demo implementation
described in the repository's [README.md](../README.md) and
[Architecture](architecture.md) docs.

---

## Table of Contents

1. [Executive Vision](#1-executive-vision)
2. [Generic EDA Trigger Architecture](#2-generic-eda-trigger-architecture)
3. [Pre-AI Filtering Pipeline](#3-pre-ai-filtering-pipeline)
4. [Alert Deduplication, Correlation, and Suppression](#4-alert-deduplication-correlation-and-suppression)
5. [Base Production Workflow](#5-base-production-workflow)
6. [Agentic AI Architecture](#6-agentic-ai-architecture)
7. [Production AI Model Selection and Deployment](#7-production-ai-model-selection-and-deployment)
8. [Knowledge Base Evolution](#8-knowledge-base-evolution)
9. [Governance, Safety, and Compliance](#9-governance-safety-and-compliance)
10. [Multi-Cluster and Multi-Tenant Scale](#10-multi-cluster-and-multi-tenant-scale)
11. [Integration Maturity](#11-integration-maturity)

---

## 1. Executive Vision

The current demo proves a powerful concept: an OpenShift alert can trigger a
fully automated chain -- from cluster diagnostics through AI-driven root cause
analysis to a remediation playbook pushed to Git and registered in Red Hat
Ansible Automation Platform -- all documented in ServiceNow without human
intervention.

But the demo has deliberate constraints that prevent direct production use:

- **Four hardcoded scenarios.** The EDA rulebook contains six rules that match
  specific `alertname` values (`KubeNodeNotReady`, `ClusterOperatorDegraded`,
  `NodeFilesystemSpaceFillingUp`, `NodeFilesystemAlmostOutOfSpace`,
  `KubeNodePressure`, `MCPDegraded`). Any other alert is silently ignored.

- **Exact-match knowledge base.** "Known incident" detection relies on an AAP
  Job Template whose name matches the pattern `Remediate <AlertName>`. There is
  no semantic similarity, no confidence scoring, and no learning from past
  resolutions beyond the existence of a named JT.

- **Static EDA throttle.** The `once_within: 3 hours` throttle prevents alert
  storms during demos but has no awareness of whether the issue is already
  being investigated, remediated, or resolved.

- **Single-shot AI.** The model receives one prompt and returns one response.
  There is no iterative reasoning, no tool calling, and no ability for the AI
  to request additional diagnostics or verify its own output.

The production vision replaces these constraints with:

| Concern | Demo | Production |
|---------|------|------------|
| Alert coverage | 6 static rules, 4 scenarios | Universal handler for any firing alert |
| Issue classification | EDA rule conditions | AI-driven triage at workflow entry |
| Duplicate suppression | EDA `once_within` timer | Stateful incident registry with correlation |
| AI reasoning | Single prompt/response | Agentic loop with tool calling and verification |
| Knowledge base | Exact JT name match | Vector similarity with confidence thresholds |
| Learning | JT + Git artifact existence | Automatic embedding of verified resolutions |
| Governance | None (demo-grade) | Approval gates, policy engine, blast radius control |
| Scale | Single cluster | Multi-cluster via Red Hat Advanced Cluster Management |

---

## 2. Generic EDA Trigger Architecture

### Current State

The EDA rulebook (`ansible/rulebooks/cluster-alert-handler.yml`) contains one
rule per alert type. Each rule hard-codes the `alertname` in its condition,
extracts a fixed set of labels into `extra_vars`, and invokes
`self-healing-workflow`. The Alertmanager configuration
(`manifests/monitoring/alertmanager-config.yaml`) uses a regex matcher that
must be updated every time a new alert type is added:

```yaml
matchers:
  - alertname=~"KubeNodeNotReady|ClusterOperatorDegraded|..."
```

This coupling means that adding a new alert requires changes in three places:
Alertmanager config, EDA rulebook, and the diagnostics playbook.

### Production Architecture

**A single universal alert handler rule** replaces all per-alert rules:

```yaml
rules:
  - name: Handle any firing alert
    condition: >-
      event.alert.status == "firing"
    throttle:
      once_within: 5 minutes
      group_by_attributes:
        - event.alert.labels.alertname
        - event.alert.labels.namespace
        - event.alert.labels.node
    action:
      run_workflow_template:
        name: self-healing-workflow
        organization: Default
        job_args:
          extra_vars:
            alert_name: "{{ event.alert.labels.alertname }}"
            alert_labels: "{{ event.alert.labels | to_json }}"
            alert_annotations: "{{ event.alert.annotations | to_json }}"
            alert_severity: "{{ event.alert.labels.severity | default('warning') }}"
            alert_fingerprint: "{{ event.alert.fingerprint | default('') }}"
```

Key design decisions:

- **Pass all labels and annotations as JSON**, not a curated subset. The AI
  triage step (not the rulebook) decides which fields matter.

- **Include the alert fingerprint.** Alertmanager generates a stable fingerprint
  per alert instance. This becomes the primary key for deduplication.

- **Lower the throttle window** from 3 hours to 5 minutes. The real
  deduplication happens in the incident registry (Section 4), not the EDA
  throttle. The EDA throttle exists only as a safety net against webhook
  floods.

- **Alertmanager matcher becomes a catch-all** for the `self-healing`
  namespace, or uses a dedicated label (`self-healing: enabled`) applied to
  alerts that should be handled:

  ```yaml
  matchers:
    - self_healing="enabled"
  ```

### Multi-Source Ingestion

Production environments generate signals beyond Prometheus alerts. The EDA
layer should support multiple event sources:

| Source | EDA Plugin | Signal Type |
|--------|-----------|-------------|
| Prometheus/Alertmanager | `ansible.eda.alertmanager` | Infrastructure alerts |
| OpenShift Logging (Loki) | `ansible.eda.webhook` + LogQL alerting | Log-based anomalies |
| Red Hat Advanced Cluster Security | `ansible.eda.webhook` | Security policy violations |
| Kubernetes audit log | `ansible.eda.webhook` + audit policy | Suspicious API calls |
| External APM (Dynatrace, Datadog) | `ansible.eda.webhook` | Application-layer signals |

Each source normalizes its payload into the same envelope schema
(`alert_name`, `alert_labels`, `alert_annotations`, `alert_severity`,
`alert_fingerprint`, `alert_source`) so the downstream workflow is
source-agnostic.

---

## 3. Pre-AI Filtering Pipeline

### Why Filter Before the AI Layer

A universal alert handler (Section 2) means every firing alert reaches the
self-healing platform. In a production OpenShift cluster, that can be hundreds
of alerts per hour -- the majority of which are transient warnings that
self-resolve within minutes, duplicates of an already-handled incident, or
low-severity informational signals that belong on a dashboard, not in an
AI-driven remediation pipeline.

Passing all of these raw alerts directly to the AI triage step is problematic:

- **GPU cost.** Every AI invocation consumes GPU tokens and inference time.
  Processing 100 transient warnings per hour at 2,000 tokens each burns
  through capacity that should be reserved for genuine incidents.
- **Latency.** If the AI model is saturated by noise, critical alerts queue
  behind informational ones.
- **False positives.** Models are more likely to hallucinate remediation
  actions when given alerts that don't actually require intervention.

The solution is a **streaming filter pipeline** that sits between alert
ingestion and the EDA/AI layer, eliminating noise before it reaches any
expensive component.

### Architecture

```
Alertmanager / External Sources
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│            Pre-AI Filtering Pipeline                     │
│                                                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │ Stage 1: Ingestion Buffer (AMQ Streams / Kafka) │    │
│  │ - Absorb alert bursts without backpressure      │    │
│  │ - Assign correlation key (node + alertname)     │    │
│  │ - Retain alerts for replay on pipeline recovery │    │
│  └────────────────────┬────────────────────────────┘    │
│                       │                                  │
│  ┌────────────────────▼────────────────────────────┐    │
│  │ Stage 2: Severity Gate                          │    │
│  │ - Drop info-level alerts (log only)             │    │
│  │ - Hold warnings in pending window (3-5 min)     │    │
│  │ - Pass critical/error immediately               │    │
│  │ - Discard pending warnings if "resolved" arrives│    │
│  └────────────────────┬────────────────────────────┘    │
│                       │                                  │
│  ┌────────────────────▼────────────────────────────┐    │
│  │ Stage 3: Deduplication                          │    │
│  │ - Check incident registry for in-flight match   │    │
│  │ - Absorb duplicates (append context, no new wf) │    │
│  │ - Pass genuinely new incidents                  │    │
│  └────────────────────┬────────────────────────────┘    │
│                       │                                  │
│  ┌────────────────────▼────────────────────────────┐    │
│  │ Stage 4: Correlation Window                     │    │
│  │ - Batch related alerts within 60-second window  │    │
│  │ - Emit one consolidated event per group         │    │
│  │ - Include all correlated alerts as context      │    │
│  └────────────────────┬────────────────────────────┘    │
│                       │                                  │
└───────────────────────┼──────────────────────────────────┘
                        │
                        ▼
                 EDA (filtered topic)
                        │
                        ▼
                 AAP Workflow → AI Triage → ...
```

### Stage 1: Ingestion Buffer (Red Hat AMQ Streams)

**Red Hat AMQ Streams** (the supported Apache Kafka distribution on OpenShift)
provides the ingestion buffer. Alertmanager (and other sources) push to a
Kafka topic (`alerts-raw`) instead of directly to the EDA webhook.

Why Kafka:

- **Burst absorption.** A node failure can generate 20+ alerts in 30 seconds.
  Kafka absorbs the burst and the stream processor consumes at its own pace.
  Without Kafka, these alerts would either overload EDA or be dropped.
- **Exactly-once processing.** Kafka Streams (or a Quarkus/Camel-K consumer)
  provides exactly-once semantics for the dedup and correlation stages.
- **Replay on failure.** If the filtering pipeline restarts, it replays from
  the last committed offset. No alerts are lost.
- **Topic-based routing.** Optionally split into `alerts-critical` and
  `alerts-standard` topics with different consumer groups and processing
  latencies.

Alertmanager integration uses a lightweight webhook-to-Kafka bridge (a 20-line
Camel-K route or a simple Go sidecar) that receives the Alertmanager webhook
payload and produces it to the `alerts-raw` topic with the alert fingerprint
as the Kafka message key.

### Stage 2: Severity Gate

Not every alert deserves AI analysis. The severity gate applies a
deterministic policy before any AI token is spent:

| Severity | Action | Rationale |
|----------|--------|-----------|
| **critical** | Pass immediately | Potential data loss or outage; no delay acceptable |
| **error** | Pass immediately | Active failure requiring investigation |
| **warning** | Hold in pending window (3-5 min) | Many warnings are transient (brief pod restarts, operator flaps, temporary resource pressure). If a `resolved` event arrives within the window, discard silently |
| **info** | Log to observability stack, do not forward | Informational alerts are for dashboards and trend analysis, not for automated remediation |

The pending window for warnings is implemented as a Kafka Streams
[session window](https://kafka.apache.org/documentation/streams/developer-guide/dsl-api.html#windowing)
keyed by alert fingerprint. When a `firing` event arrives for a warning-level
alert, the processor starts a window. If a `resolved` event with the same
fingerprint arrives before the window closes, both events are suppressed. If
the window expires without a resolution, the `firing` event is forwarded to
Stage 3.

This single filter eliminates the largest source of noise in production
clusters. In typical OpenShift environments, 60-80% of Alertmanager firings
are transient warnings that self-resolve.

### Stage 3: Deduplication

Alerts that survive the severity gate are checked against the incident
registry (described in detail in Section 4). If a matching in-flight incident
exists, the alert is absorbed as additional context (appended to the incident
record) but no new workflow is spawned.

This stage also handles the specific concern of **repeated firings during
remediation**: once the platform begins working on an incident, every
subsequent alert with the same fingerprint or correlation key is silently
absorbed until the incident reaches `resolved` or `escalated`.

### Stage 4: Correlation Window

Related alerts that survive dedup are batched into a single incident event.
The correlation window groups alerts that share a common attribute (same node,
same namespace, same operator) within a configurable time window (default: 60
seconds).

Example: a worker node failure generates:

| Time | Alert | Fingerprint |
|------|-------|-------------|
| T+0s | `KubeNodeNotReady` (node=worker-2) | fp-001 |
| T+5s | `KubeNodePressure` (node=worker-2, condition=DiskPressure) | fp-002 |
| T+12s | `NodeFilesystemSpaceFillingUp` (instance=worker-2) | fp-003 |
| T+30s | `TargetDown` (namespace=app-ns, pod on worker-2) | fp-004 |

Without correlation, each alert would trigger a separate workflow. With
the 60-second correlation window keyed by `node=worker-2`, all four alerts
are batched into a single event envelope:

```json
{
  "incident_type": "correlated",
  "primary_alert": "KubeNodeNotReady",
  "correlation_key": "node:worker-2",
  "alerts": [
    {"alertname": "KubeNodeNotReady", "fingerprint": "fp-001", ...},
    {"alertname": "KubeNodePressure", "fingerprint": "fp-002", ...},
    {"alertname": "NodeFilesystemSpaceFillingUp", "fingerprint": "fp-003", ...},
    {"alertname": "TargetDown", "fingerprint": "fp-004", ...}
  ],
  "severity": "critical",
  "window_start": "2026-03-15T14:22:00Z",
  "window_end": "2026-03-15T14:23:00Z"
}
```

One workflow is launched. The AI triage step receives all four alerts as
context, giving it a much richer picture of the incident than any single
alert would provide.

### EDA Integration

The output of the filtering pipeline is a Kafka topic (`alerts-filtered`).
EDA consumes from this topic using the `ansible.eda.kafka` source plugin
instead of the direct Alertmanager webhook:

```yaml
sources:
  - ansible.eda.kafka:
      host: amq-streams-kafka-bootstrap.amq-streams.svc:9092
      topic: alerts-filtered
      group_id: eda-self-healing
      offset: latest

rules:
  - name: Handle filtered incident event
    condition: event.body.primary_alert is defined
    action:
      run_workflow_template:
        name: self-healing-workflow
        organization: Default
        job_args:
          extra_vars:
            alert_name: "{{ event.body.primary_alert }}"
            alert_labels: "{{ event.body.alerts[0].labels | to_json }}"
            alert_annotations: "{{ event.body.alerts[0].annotations | to_json }}"
            alert_severity: "{{ event.body.severity }}"
            alert_fingerprint: "{{ event.body.alerts[0].fingerprint }}"
            correlated_alerts: "{{ event.body.alerts | to_json }}"
            correlation_key: "{{ event.body.correlation_key }}"
```

### What Reaches the AI

After the four filtering stages, the AI triage step receives only:

- **Genuine incidents** (not transient warnings that self-resolved).
- **De-duplicated** (not repeated firings of the same alert).
- **Correlated** (a single event with all related alerts bundled as context).
- **Severity-validated** (only critical, error, or persistent warnings).

This reduces the AI invocation volume by an estimated 70-90% compared to
forwarding all raw alerts, while ensuring that every real incident is handled
promptly with the richest possible context.

### Red Hat Product Alignment

| Component | Red Hat Product | Operator |
|-----------|----------------|----------|
| Kafka broker + topics | Red Hat AMQ Streams 2.x | `amqstreams` (from Red Hat Operator catalog) |
| Stream processor | Red Hat Build of Apache Camel (Camel-K) or Quarkus | `camel-k` or custom Deployment |
| EDA Kafka consumer | `ansible.eda.kafka` source plugin | Built into EDA Controller |
| Incident registry | PostgreSQL (shared or dedicated) | `crunchy-postgres-operator` or AAP-managed |

### Implementation Effort Analysis

The filtering pipeline described above ranges from off-the-shelf operator
installs to moderate custom development. This subsection breaks down each
component so teams can estimate cost and staffing realistically.

**Off-the-shelf (operator install + YAML configuration, no custom code)**

| Component | What It Takes | Effort |
|-----------|--------------|--------|
| AMQ Streams broker + topics | Install `amqstreams` operator, define `Kafka` CR, create `KafkaTopic` CRs for `alerts-raw` and `alerts-filtered` | 1-2 days (including sizing, TLS, retention tuning) |
| EDA rulebook switch to Kafka | Replace `ansible.eda.alertmanager` source with `ansible.eda.kafka` in the rulebook YAML (plugin ships with EDA Controller) | Hours |

**Light custom development (small, well-scoped)**

The **webhook-to-Kafka bridge** is needed because Alertmanager speaks HTTP
webhooks while Kafka speaks its own protocol. Three options, all small:

| Option | Size | Notes |
|--------|------|-------|
| Camel-K Integration CR | ~20 lines YAML | `from("platform-http:/endpoint").to("kafka:alerts-raw")` -- the Red Hat Build of Apache Camel operator handles the rest |
| Go sidecar | ~100 lines | HTTP server + `confluent-kafka-go` producer, containerized with UBI9 |
| Python sidecar | ~100 lines | Flask + `confluent-kafka` producer, containerized with UBI9 |

Effort: **1-3 days** depending on language familiarity.

**Moderate custom development (the core stream processor)**

The stream processor implementing Stages 2-4 is where the real engineering
work lives:

| Stage | Logic | Complexity | Estimated Code |
|-------|-------|------------|---------------|
| Severity gate | Route/filter by `severity` label value | Trivial | ~50 lines |
| Pending window (warnings) | Kafka Streams `SessionWindows` keyed by alert fingerprint; hold `firing`, cancel if `resolved` arrives before window closes | Medium | ~200-300 lines |
| Dedup against incident registry | Query PostgreSQL (REST or JDBC) on every event to check for in-flight match | Medium | ~100-200 lines |
| Correlation window | Kafka Streams `SessionWindows` keyed by correlation key (node, namespace); accumulate alerts, emit consolidated event on window close | High | ~300-400 lines |

Total stream processor: **~800-1,200 lines of Java/Kotlin** (or equivalent
Quarkus reactive code). Realistically **2-3 weeks** of development including
tests, edge cases (e.g., a warning-level alert arrives first but a critical
follows 10 seconds later and should upgrade the group severity), and
integration testing against a real Kafka cluster.

**Incident registry (PostgreSQL schema + API)**

| Component | Description | Estimated Code |
|-----------|-------------|---------------|
| Database schema | ~5 tables: incidents, alerts, state_transitions, correlation_groups, cooldowns | ~100 lines SQL |
| REST API or JDBC layer | CRUD operations for the stream processor and workflow steps | ~500-800 lines (FastAPI or Quarkus) |

Effort: **1-2 weeks** including schema design, migration scripts, and the API.

**Total effort for the full Kafka-based pipeline:**

| Component | Custom Code | Effort |
|-----------|------------|--------|
| AMQ Streams operator + topics | None (YAML) | 1-2 days |
| Webhook-to-Kafka bridge | ~20-100 lines | 1-3 days |
| EDA rulebook switch to Kafka | None (YAML) | Hours |
| Stream processor (all 4 stages) | ~800-1,200 lines | 2-3 weeks |
| Incident registry (schema + API) | ~500-800 lines | 1-2 weeks |
| Integration testing | Test suite | 1 week |
| **Total** | **~1,500-2,200 lines** | **5-7 weeks** |

### Alternative Approaches (Reduced Effort)

If the full Kafka pipeline is too heavy for an initial production deployment,
three lighter alternatives trade sophistication for speed. Each delivers
progressively less filtering capability but at substantially lower cost.

**Option A: EDA-native event filter (no Kafka)**

Keep the current `ansible.eda.alertmanager` webhook source. Implement the
severity gate and fingerprint-based dedup as a custom
[EDA event filter plugin](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.5/html/using_event-driven_ansible_automation/eda-user-guide-custom-event-filter)
-- a single Python file that runs inside the EDA Controller process.

| Capability | Supported | Notes |
|-----------|-----------|-------|
| Severity gate (drop info, defer warnings) | Yes | Stateless filter logic |
| Fingerprint dedup | Partial | In-memory dict with TTL; lost on EDA restart |
| Correlation window | No | EDA filters are per-event; no native windowing |
| Burst buffering / replay | No | Alertmanager webhook can still overload EDA |

Effort: **~1-2 weeks.** Best for teams that want immediate noise reduction
without new infrastructure.

**Option B: Alertmanager-native grouping + inhibition (no custom code)**

Push filtering logic entirely into Alertmanager's built-in features:

- `inhibit_rules` to suppress `KubeNodePressure` when `KubeNodeNotReady` is
  firing on the same node.
- `group_by: [node]` to batch node-related alerts into a single webhook call.
- `group_wait: 60s` to approximate the correlation window.
- Route-level `matchers` to silence `info`-level alerts entirely.
- `mute_time_intervals` for known maintenance windows.

| Capability | Supported | Notes |
|-----------|-----------|-------|
| Severity gate | Yes | Route matchers filter by severity |
| Grouping / correlation | Partial | `group_by` is coarser than Kafka session windows |
| Inhibition (causal suppression) | Yes | Suppresses child alerts when parent is firing |
| Dedup against incident registry | No | No external state awareness |
| Burst buffering / replay | No | Webhook delivery is fire-and-forget |

Effort: **~2-3 days** of Alertmanager configuration tuning. Zero custom code.
Best for teams that need quick wins with no new components.

**Option C: Hybrid -- Alertmanager config + EDA event filter (recommended first step)**

Combine Options A and B: use Alertmanager for the heavy lifting (grouping,
inhibition, severity routing) and a lightweight EDA event filter for incident
registry dedup. Skip Kafka entirely for the initial deployment.

| Capability | Handled By |
|-----------|-----------|
| Severity gate | Alertmanager route matchers |
| Alert grouping | Alertmanager `group_by` + `group_wait` |
| Causal inhibition | Alertmanager `inhibit_rules` |
| In-flight incident dedup | EDA event filter (Python, queries PostgreSQL) |
| Burst buffering / replay | Not available (add Kafka later if needed) |

Effort: **~1-2 weeks total.** This approach delivers an estimated 80% of the
noise reduction at ~20% of the full Kafka pipeline cost. It is the
**recommended starting point** for a first production deployment. Kafka can
be introduced later when alert volume, reliability SLAs, or multi-source
ingestion requirements justify the additional infrastructure.

### Recommended Adoption Path

```
Phase 1 (weeks 1-2)          Phase 2 (weeks 3-8)          Phase 3 (future)
─────────────────────         ─────────────────────         ─────────────────
Alertmanager config           + EDA event filter            + AMQ Streams
  - inhibit_rules               - Severity gate               - Kafka topics
  - group_by node               - Incident registry           - Stream processor
  - silence info alerts          dedup (PostgreSQL)            - Correlation windows
  - group_wait 60s              - Cooldown logic              - Replay / exactly-once
                                                              - Multi-source ingestion
                                                                (Loki, RHACS, audit)

Noise reduction: ~50%        Noise reduction: ~80%         Noise reduction: ~90%+
Custom code: 0 lines         Custom code: ~500 lines       Custom code: ~2,000 lines
New infra: none              New infra: PostgreSQL table    New infra: AMQ Streams
```

---

## 4. Alert Deduplication, Correlation, and Suppression

### The Problem

When a worker node fails, it generates a cascade of alerts: `KubeNodeNotReady`,
`KubeNodePressure`, `NodeFilesystemSpaceFillingUp`, pod eviction alerts, and
potentially operator-degraded alerts for components that had pods on that node.
In the current demo, the EDA `once_within: 3 hours` throttle suppresses
repeated firings of the *same* alert, but it cannot:

- Correlate *different* alerts that share a root cause (same node, same
  time window).
- Know that a workflow is already in progress for this node.
- Prevent a new workflow from launching when the previous one is still
  remediating the same issue.

### Incident State Machine

Every incident tracked by the platform follows a defined lifecycle:

```
                  ┌──────────────────────────────────────────┐
                  │                                          │
                  ▼                                          │
┌──────────┐  ┌──────────┐  ┌───────────┐  ┌────────────┐  │  ┌──────────┐
│ Detected │─►│ Triaging │─►│ Analyzing │─►│Remediating │──┼─►│ Resolved │
└──────────┘  └──────────┘  └───────────┘  └────────────┘  │  └──────────┘
                  │               │              │          │
                  │               │              │          │  ┌───────────┐
                  │               ▼              ▼          └─►│ Escalated │
                  │          ┌─────────┐   ┌─────────┐        └───────────┘
                  └─────────►│Absorbing│   │Retrying │
                             └─────────┘   └─────────┘
```

- **Detected**: A new alert has arrived and no matching in-flight incident
  exists. The incident is created in the registry.
- **Triaging**: The AI triage step is classifying the alert and determining
  severity and blast radius.
- **Analyzing**: Diagnostics are being gathered and the AI is performing root
  cause analysis.
- **Remediating**: A remediation playbook is executing.
- **Absorbing**: A new alert arrived that correlates with an in-flight
  incident. The alert is logged as additional context but no new workflow is
  spawned.
- **Retrying**: Post-remediation verification failed; the system is retrying
  with an adjusted approach.
- **Resolved**: Remediation succeeded and the alert has cleared.
- **Escalated**: The system has exhausted its autonomous capabilities and has
  handed off to a human operator.

### Incident Registry

The incident registry is a lightweight stateful store that maps alert
fingerprints to incident records. It must support three operations:

1. **Lookup**: Given an alert fingerprint (or a correlation key derived from
   labels), return the matching in-flight incident if one exists.
2. **Create**: Register a new incident with an initial state and the
   originating alert.
3. **Update**: Transition the incident to a new state, append correlated
   alerts, record remediation outcomes.

Implementation options (in order of preference for production):

| Option | Pros | Cons |
|--------|------|------|
| PostgreSQL (shared with AAP) | ACID, SQL queries, no new infra | Schema migration, coupling |
| Redis (in-cluster) | Fast, TTL-based expiry, pub/sub | Additional component, persistence config |
| Kubernetes ConfigMap/CR | No external dependency | Size limits, no transactions, poor query |
| ServiceNow incident table | Single source of truth | Latency, external dependency |

The recommended approach is a **PostgreSQL table** colocated with the AAP
Controller database (or a dedicated instance), accessed by a lightweight
FastAPI sidecar deployed alongside the EDA controller in the `aap` namespace.

### Correlation Logic

Alerts are correlated into the same incident when they share:

- The **same node** within a configurable time window (default: 10 minutes).
- The **same namespace + workload** within a time window.
- The **same operator name** (e.g., multiple conditions on the same
  ClusterOperator).
- An explicit **causal link** (e.g., `KubeNodeNotReady` and all pod eviction
  alerts on that node).

Correlation is performed at the EDA layer *before* the workflow is invoked.
The EDA event filter plugin (or sidecar service) queries the incident registry
and either:

- **Creates a new incident** and launches the workflow, or
- **Absorbs the alert** into an existing incident (updates the registry,
  optionally sends a webhook to the running workflow to enrich diagnostics).

### Cooldown and Re-fire

After an incident reaches `Resolved`, a cooldown window (default: 15 minutes)
prevents the same alert fingerprint from creating a new incident. If the alert
re-fires after the cooldown, it is treated as a genuinely new occurrence.

If the alert re-fires *during* the cooldown, it is logged as a **regression
signal** -- the remediation may not have been effective. This triggers an
automatic escalation to the human operator with the remediation log attached.

### Suppression During Remediation

This is the critical production requirement the user identified: *how to avoid
working on the same issue when alerts keep firing during analysis and
resolution.*

The answer is a two-layer gate:

1. **EDA layer (fast path)**: The EDA event filter checks the incident registry
   before invoking `run_workflow_template`. If a matching incident is in any
   active state (`triaging`, `analyzing`, `remediating`, `retrying`), the
   alert is absorbed with no workflow invocation.

2. **Workflow layer (safety net)**: The first step of the AAP workflow
   (`check-incident-registry`) queries the registry. If the incident was
   already absorbed between the EDA check and the workflow launch (race
   condition), the workflow exits gracefully with `set_stats` recording the
   suppression reason. This handles the edge case where two EDA events pass
   the filter simultaneously.

```
Alert arrives
     │
     ▼
┌─────────────────────┐
│ EDA event filter     │
│ Query incident       │
│ registry             │
└────────┬────────────┘
         │
    ┌────┴────┐
    │ Match?  │
    └────┬────┘
     Yes │        No
         │         │
         ▼         ▼
  ┌──────────┐  ┌───────────────┐
  │ Absorb   │  │ Create        │
  │ (no wf)  │  │ incident +    │
  └──────────┘  │ launch wf     │
                └───────────────┘
```

---

## 5. Base Production Workflow

### Current Workflow

The demo uses a linear AAP Workflow Job Template with a single branch point:

```
gather-diagnostics → create-snow-incident → check-knowledge-base
                                                   │
                                           ┌───────┴───────┐
                                        success         failure
                                           │               │
                                   invoke-ai-new    invoke-ai-known
                                           │               │
                                           └───────┬───────┘
                                                   │
                                           store-resolution
```

The branch is implemented by `check-knowledge-base.yml` calling
`ansible.builtin.fail` when a known JT exists, which routes the workflow to
the `failure_nodes` path.

### Production Workflow

The production workflow adds five capabilities the demo lacks: pre-workflow
deduplication, AI-driven triage, approval gates, post-remediation verification,
and closed-loop learning.

```
┌─────────────────────────────────────────────────────────────────────┐
│                    AAP Workflow Job Template                        │
│                                                                    │
│  ┌────────────────┐     ┌──────────────────┐                       │
│  │ Check Incident │────►│ AI Triage +      │                       │
│  │ Registry       │     │ Classification   │                       │
│  └───────┬────────┘     └────────┬─────────┘                       │
│     (abort if                    │                                  │
│      duplicate)                  ▼                                  │
│                         ┌──────────────────┐                       │
│                         │ Gather           │                       │
│                         │ Diagnostics      │                       │
│                         └────────┬─────────┘                       │
│                                  │                                  │
│                                  ▼                                  │
│                         ┌──────────────────┐                       │
│                         │ Create ITSM      │                       │
│                         │ Ticket           │                       │
│                         └────────┬─────────┘                       │
│                                  │                                  │
│                                  ▼                                  │
│                         ┌──────────────────┐                       │
│                         │ Knowledge Base   │                       │
│                         │ Search (vector)  │                       │
│                         └────────┬─────────┘                       │
│                                  │                                  │
│                     ┌────────────┼────────────┐                    │
│                high confidence   │        no match                 │
│                     │        medium           │                    │
│                     ▼        confidence       ▼                    │
│             ┌──────────────┐     │     ┌──────────────┐            │
│             │ Auto-        │     │     │ Agentic RCA  │            │
│             │ Remediate    │     │     │ Loop         │            │
│             └──────┬───────┘     │     └──────┬───────┘            │
│                    │             ▼            │                    │
│                    │      ┌──────────────┐    │                    │
│                    │      │ Human        │    │                    │
│                    │      │ Approval     │    │                    │
│                    │      │ Gate         │    │                    │
│                    │      └──────┬───────┘    │                    │
│                    │             │             │                    │
│                    │      ┌──────┴──────┐     │                    │
│                    │   approved     rejected   │                    │
│                    │      │            │       │                    │
│                    │      ▼            ▼       │                    │
│                    │  ┌────────┐ ┌──────────┐  │                    │
│                    │  │Execute │ │ Escalate │  │                    │
│                    │  └───┬────┘ └──────────┘  │                    │
│                    │      │                    │                    │
│                    └──────┼────────────────────┘                    │
│                           │                                        │
│                           ▼                                        │
│                  ┌──────────────────┐                               │
│                  │ Post-Remediation │                               │
│                  │ Verification     │                               │
│                  └────────┬─────────┘                               │
│                           │                                        │
│                    ┌──────┴──────┐                                  │
│                 success      failure                               │
│                    │            │                                   │
│                    ▼            ▼                                   │
│             ┌────────────┐ ┌───────────┐                           │
│             │ Learn +    │ │ Retry or  │                           │
│             │ Close ITSM │ │ Escalate  │                           │
│             └────────────┘ └───────────┘                           │
│                                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

### New Workflow Steps

**Check Incident Registry** (new, first step): Queries the incident registry
for a matching in-flight incident. If found, the workflow exits immediately
with `set_stats` recording the suppression. If not found, the incident is
registered as `triaging`.

**AI Triage and Classification** (new): Instead of hardcoded EDA rule
conditions determining the alert type, the AI model receives the raw alert
labels and annotations and produces:

- **Issue category**: compute, networking, storage, operator, security,
  configuration, application.
- **Estimated severity**: informational, warning, critical, emergency.
- **Estimated blast radius**: single pod, single node, single namespace,
  cluster-wide.
- **Recommended diagnostic depth**: standard, extended (include logs, events,
  metrics), deep (include node-level system checks).

This classification drives downstream behavior: diagnostic scope, ITSM ticket
priority, and approval gate thresholds.

**Approval Gate** (new): A configurable decision point between RCA and
execution. The gate evaluates a policy matrix:

| Blast Radius | Severity | Action |
|-------------|----------|--------|
| Single pod | Any | Auto-approve |
| Single node | Warning | Auto-approve |
| Single node | Critical | Require approval (15-minute timeout) |
| Namespace-wide | Any | Require approval |
| Cluster-wide | Any | Require approval + senior on-call |

Approval is requested via ServiceNow Change Request (not just work notes on
the Incident). If the timeout expires without approval, the incident is
escalated.

Implementation: The approval gate is an AAP Workflow node that launches a
"wait-for-approval" Job Template. This JT polls the ServiceNow Change Request
for an `approved` state, using a configurable timeout. AAP's native
[Workflow Approval](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.5/html/using_automation_execution/controller-workflow-approvals)
nodes are also an option for approval within AAP itself.

**Post-Remediation Verification** (new): After the remediation playbook
executes, a verification playbook runs the same diagnostics as the initial
step and compares before/after state. It also checks whether the original
alert has cleared in Prometheus (using the Alertmanager API or a Prometheus
`query` on `ALERTS{alertname="...", alertstate="firing"}`). If the alert
is still firing after a grace period, the remediation is marked as failed.

**Learn and Close** (enhanced): The current `store-incident-resolution.yml`
only records metadata in `set_stats`. The production version:

1. Embeds the resolution record (alert signature + diagnostics fingerprint +
   RCA + playbook + outcome) into the LlamaStack vector store.
2. Updates the ServiceNow Incident to `Resolved` with the full resolution
   summary.
3. Creates a ServiceNow Knowledge Article if the resolution is novel.
4. Updates the incident registry to `Resolved` with a cooldown timestamp.

---

## 6. Agentic AI Architecture

### Current AI Interaction

The demo uses a single-shot prompt-response pattern:

1. The Ansible playbook builds a long prompt containing diagnostics,
   Lightspeed RAG context, and operational knowledge base context.
2. It calls LlamaStack `/v1/chat/completions` once.
3. It parses the response by splitting on `---PLAYBOOK---` and
   `---EXTRA_VARS---` markers.

This works for well-understood scenarios but fails when:

- The initial diagnostics are insufficient (the model needs to request more
  data).
- The first remediation attempt doesn't work (the model needs to reason about
  why and try something different).
- The issue is complex and requires multiple investigation steps before a root
  cause can be identified.

### Agentic Loop

The production architecture replaces the single-shot pattern with a
**ReAct (Reasoning + Acting) loop** where the AI model iteratively reasons
about the problem, calls tools to gather information or take action, observes
the results, and repeats until it reaches a conclusion.

```
┌─────────────────────────────────────────────────┐
│               Agentic RCA Loop                  │
│                                                 │
│   ┌──────────┐                                  │
│   │ System   │  "You are an OpenShift SRE.      │
│   │ Prompt   │   Investigate this alert using    │
│   │          │   the tools available to you."    │
│   └────┬─────┘                                  │
│        │                                        │
│        ▼                                        │
│   ┌──────────┐    ┌──────────────┐              │
│   │ Reason   │───►│ Tool Call    │              │
│   │ (think)  │    │ (act)        │              │
│   └──────────┘    └──────┬───────┘              │
│        ▲                 │                      │
│        │                 ▼                      │
│        │          ┌──────────────┐              │
│        └──────────│ Observe      │              │
│                   │ (tool result)│              │
│                   └──────┬───────┘              │
│                          │                      │
│                   ┌──────┴──────┐               │
│               continue      done                │
│                   │            │                 │
│                   ▼            ▼                 │
│              (loop back)  ┌──────────┐          │
│                           │ Final    │          │
│                           │ Answer   │          │
│                           │ (RCA +   │          │
│                           │ playbook)│          │
│                           └──────────┘          │
│                                                 │
│   Guardrails:                                   │
│   - Max 15 iterations                           │
│   - Max 30,000 tokens                           │
│   - Read-only tools only during investigation   │
│   - Write tools only after explicit "plan"      │
│     step                                        │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Tool Definitions

The agentic model needs access to a defined set of tools. Each tool is
registered with LlamaStack's tool API and exposed to the model during
chat completions with `tool_choice: "auto"`.

| Tool | Description | Read/Write | Risk |
|------|-------------|------------|------|
| `oc_get` | Query any Kubernetes resource by kind, name, namespace | Read | Low |
| `oc_describe` | Get detailed description of a resource | Read | Low |
| `oc_logs` | Retrieve container logs (with tail limit) | Read | Low |
| `query_prometheus` | Execute a PromQL query against Thanos/Prometheus | Read | Low |
| `query_loki` | Execute a LogQL query against Loki | Read | Low |
| `search_knowledge_base` | Vector similarity search in ops KB | Read | Low |
| `search_lightspeed` | Query OpenShift Lightspeed for documentation | Read | Low |
| `update_itsm_ticket` | Add work notes to the ServiceNow incident | Write | Low |
| `create_playbook` | Write an Ansible playbook to the Git repo | Write | Medium |
| `execute_playbook` | Launch an AAP Job Template by name | Write | High |
| `patch_resource` | Apply a JSON patch to a Kubernetes resource | Write | High |

Write tools are **gated by the approval policy** (Section 5). During the
investigation phase, only read tools are available. The model must produce
a `plan` output before write tools are unlocked.

### Implementation with LlamaStack

LlamaStack (already deployed in the demo) supports tool-use through its
`/v1/chat/completions` endpoint with `tools` parameter. The agentic loop
is implemented as an Ansible playbook that:

1. Sends the initial prompt with tool definitions.
2. Receives the model response.
3. If the response contains `tool_calls`, executes each tool call (via
   Ansible modules or `ansible.builtin.uri`), collects the results, and
   sends them back as `tool` role messages.
4. Repeats until the model returns a final text response (no tool calls)
   or the iteration/token budget is exhausted.

```yaml
# Pseudocode: Agentic loop in Ansible
- name: Agentic RCA loop
  ansible.builtin.include_tasks: agentic-iteration.yml
  loop: "{{ range(1, max_iterations + 1) | list }}"
  loop_control:
    loop_var: iteration
  when: not (agentic_complete | default(false) | bool)
```

Each iteration task file:
1. Calls LlamaStack with the accumulated message history.
2. Checks if the response has `tool_calls`.
3. If yes, dispatches each tool call to the appropriate handler, appends
   results to the message history.
4. If no, extracts the final RCA and playbook from the text response,
   sets `agentic_complete: true`.

### Guardrails

Production agentic systems require strict boundaries:

- **Iteration limit**: Maximum 15 reasoning cycles. If the model hasn't
  reached a conclusion by then, it must produce its best-effort RCA and
  flag the incident for human review.

- **Token budget**: Maximum 30,000 tokens (input + output combined across all
  iterations). Prevents runaway context growth from verbose tool outputs.

- **Tool output truncation**: Each tool result is truncated to 4,000
  characters. The model can request a more specific query if it needs detail
  from a large output.

- **Action allow-list**: Write tools can only target namespaces and resource
  types defined in a policy ConfigMap. For example, the model cannot
  `patch_resource` in `openshift-*` namespaces without explicit policy
  approval.

- **Dry-run enforcement**: The `execute_playbook` tool always runs in
  `--check` mode first. The model sees the dry-run output and must
  explicitly call `execute_playbook_confirm` (a separate tool) to proceed
  with the actual run.

- **Human escalation**: If the model outputs a `NEEDS_HUMAN` marker at any
  point, the loop terminates and the incident is escalated immediately.

### Observability

Every iteration of the agentic loop is recorded as a structured trace:

```json
{
  "incident_id": "INC0012345",
  "iteration": 3,
  "thought": "The node shows DiskPressure. Let me check which filesystem...",
  "tool_call": {
    "name": "oc_get",
    "arguments": {"kind": "Node", "name": "worker-2", "output": "jsonpath={.status.conditions}"}
  },
  "tool_result": "[{\"type\":\"DiskPressure\",\"status\":\"True\",...}]",
  "tokens_used": 1847,
  "duration_ms": 2340
}
```

These traces are stored alongside the incident record and surfaced in:
- The ServiceNow incident work notes (summarized).
- The AAP job output (full detail).
- An OpenTelemetry-compatible trace (for Jaeger/Grafana Tempo visualization).

---

## 7. Production AI Model Selection and Deployment

### Model Requirements

The production model must satisfy capabilities that go beyond simple text
generation:

| Requirement | Why | Minimum Bar |
|-------------|-----|-------------|
| **Tool-use (function calling)** | Agentic loop requires structured tool invocation | Reliable JSON tool call output with >95% format compliance |
| **Large context window** | Diagnostics, RAG context, and multi-turn conversation | 32K tokens minimum, 128K preferred |
| **Strong reasoning** | RCA requires causal inference from complex, noisy data | Competitive with GPT-4-class on reasoning benchmarks |
| **Low hallucination for commands** | Generated playbooks must use real module names and correct syntax | Validated against Ansible lint and `kubernetes.core` module schema |
| **Instruction following** | System prompt compliance for output format, guardrails | Near-perfect adherence to structured output instructions |

### Model Candidates

Models are evaluated on the requirements above. All candidates must be
deployable on Red Hat OpenShift AI using vLLM and the Red Hat Model Catalog.

| Model | Parameters | Context | Tool-Use | Deployment |
|-------|-----------|---------|----------|------------|
| **IBM Granite 3.1** (8B/34B) | 8B or 34B | 128K | Native | Red Hat Model Catalog, single/multi-GPU |
| **Llama 3.x** (70B/405B) | 70B or 405B | 128K | Native (3.1+) | Multi-GPU (A100/H100), quantized on L4 |
| **Mistral Large 2** | 123B | 128K | Native | Multi-GPU |
| **Mistral Small 3.1** (current demo) | 24B | 32K | Limited | Single L4 (INT4) |
| **DeepSeek-R1** (distilled) | 70B | 128K | Via prompting | Multi-GPU |

Recommendation: Start with **IBM Granite 3.1 34B** for production. It is
available in the Red Hat Model Catalog, has native tool-use support, a 128K
context window, and is optimized for enterprise operational tasks. It can run
on 2x NVIDIA L4 GPUs with INT4 quantization or a single A100/H100.

For organizations with access to larger GPU infrastructure (4x A100 or 2x
H100), **Llama 3.1 70B** provides stronger reasoning at the cost of higher
latency and resource requirements.

### Serving Architecture

```
┌─────────────────────────────────────────────┐
│        OpenShift AI - Model Serving         │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │   vLLM ServingRuntime (primary)     │    │
│  │   Granite 3.1 34B (INT4)           │    │
│  │   2x NVIDIA L4 / 1x A100          │    │
│  │   KServe InferenceService          │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │   vLLM ServingRuntime (fallback)    │    │
│  │   Granite 3.1 8B (INT4)            │    │
│  │   1x NVIDIA L4                     │    │
│  │   KServe InferenceService          │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │   Model Registry                    │    │
│  │   Version tracking, A/B routing     │    │
│  └─────────────────────────────────────┘    │
│                                             │
└─────────────────────────────────────────────┘
```

Key production considerations:

- **Fallback chain**: If the primary model is unavailable (GPU node failure,
  OOM, model loading), requests fall back to the 8B model. If that also fails,
  the workflow skips AI analysis and escalates directly to a human operator
  with the raw diagnostics attached.

- **GPU autoscaling**: KServe supports scale-to-zero and autoscaling based on
  request queue depth. For production SLAs, maintain a minimum of 1 replica
  to avoid cold-start latency.

- **Model versioning**: Use the OpenShift AI Model Registry to track model
  versions. Before promoting a new model version to production, run the
  evaluation suite (below) and compare against the baseline.

### Evaluation Framework

Before deploying a model to production, it must pass an evaluation suite
based on historical incidents:

| Metric | Target | How Measured |
|--------|--------|--------------|
| **RCA accuracy** | >85% correct root cause identification | Human-labeled benchmark of 100+ incidents |
| **Playbook correctness** | >90% syntactically valid, >75% functionally correct | Ansible lint + dry-run on test cluster |
| **Tool-call format compliance** | >95% | Automated schema validation |
| **False positive rate** | <5% unnecessary remediation actions | Comparison with human SRE decisions |
| **Mean time to RCA** | <5 minutes (wall clock) | End-to-end timing on benchmark set |
| **Hallucination rate** | <2% fabricated module names or API paths | Automated cross-reference against module docs |

---

## 8. Knowledge Base Evolution

### Current State

The demo has two disconnected knowledge base mechanisms:

1. **Known incident detection** (`check-knowledge-base.yml`): Builds an
   expected Job Template name (`Remediate <AlertName> [- qualifier]`) and
   queries the AAP Controller API for a JT with that exact name. This is a
   **string match**, not semantic similarity.

2. **Operational knowledge base** (LlamaStack vector store): Static markdown
   runbooks from `knowledge-base/runbooks/` and `knowledge-base/references/`
   are embedded and searched during the new-incident AI prompt. This provides
   RAG context but does not influence the known/new branching decision.

3. **Store resolution** (`store-incident-resolution.yml`): Records metadata in
   `set_stats` only. Nothing is written to a persistent store or embedded for
   future retrieval.

### Production Knowledge Base Architecture

```
┌──────────────────────────────────────────────────────┐
│                 Knowledge Base Layer                  │
│                                                      │
│  ┌──────────────────┐   ┌──────────────────────┐     │
│  │ Incident Memory  │   │ Operational Runbooks │     │
│  │ (vector store)   │   │ (vector store)       │     │
│  │                  │   │                      │     │
│  │ - Past incidents │   │ - Curated runbooks   │     │
│  │ - Alert+diag     │   │ - RH KB articles     │     │
│  │   fingerprints   │   │ - Post-mortems       │     │
│  │ - RCA + playbook │   │ - Vendor docs        │     │
│  │ - Outcome        │   │                      │     │
│  └────────┬─────────┘   └──────────┬───────────┘     │
│           │                        │                  │
│           └──────────┬─────────────┘                  │
│                      │                                │
│                      ▼                                │
│           ┌──────────────────┐                        │
│           │ Unified Search   │                        │
│           │ API              │                        │
│           │ (confidence      │                        │
│           │  scoring)        │                        │
│           └──────────────────┘                        │
│                                                      │
└──────────────────────────────────────────────────────┘
```

### Incident Memory

Every resolved incident is embedded as a structured document:

```json
{
  "alert_signature": {
    "alertname": "KubeNodeNotReady",
    "severity": "warning",
    "labels_hash": "sha256:abc123..."
  },
  "diagnostics_fingerprint": "sha256:def456...",
  "rca": "The kubelet process on worker-2 stopped responding...",
  "playbook_path": "playbooks/remediate-kubenodenotready.yml",
  "extra_vars_schema": {"target_node": "string"},
  "outcome": "resolved",
  "resolution_time_seconds": 340,
  "timestamp": "2026-03-15T14:22:00Z",
  "snow_incident": "INC0012345",
  "verified": true
}
```

The embedding is generated from a concatenation of the alert signature, RCA
text, and playbook contents. This allows semantic matching: a `KubeNodeNotReady`
caused by kubelet crash will match closely with past kubelet-crash incidents
even if the node name, timestamp, and exact error message differ.

### Confidence-Based Routing

The known/new decision is no longer a binary JT-name match. Instead, the
workflow queries the incident memory with the current alert signature and
diagnostics, receives a list of matches with confidence scores, and routes
based on thresholds:

| Confidence | Routing | Human Involvement |
|------------|---------|-------------------|
| **>0.90** (high) | Auto-remediate using the matched playbook and AI-derived extra_vars | None (post-remediation notification only) |
| **0.60 - 0.90** (medium) | Present the matched resolution as a suggestion; require human approval before execution | Approval gate with matched RCA for review |
| **<0.60** (low) | Full agentic RCA loop; no prior resolution is assumed | Human reviews AI-generated playbook before first execution |

The thresholds are configurable per alert category and per organization risk
tolerance.

### Continuous Learning Loop

```
Incident resolved
       │
       ▼
┌──────────────────┐
│ Verification     │
│ passed?          │
└──────┬───────────┘
    Yes │
       ▼
┌──────────────────┐     ┌─────────────────────┐
│ Embed resolution │────►│ Incident Memory     │
│ into vector      │     │ (vector store)      │
│ store            │     └─────────────────────┘
└──────────────────┘
       │
       ▼
┌──────────────────┐     ┌─────────────────────┐
│ Create/update    │────►│ ServiceNow          │
│ Knowledge        │     │ Knowledge Base      │
│ Article          │     └─────────────────────┘
└──────────────────┘
```

Only **verified** resolutions (post-remediation check passed, alert cleared)
are embedded. Failed or partially-successful remediations are stored
separately as negative examples that the AI can learn from ("this approach
was tried for this alert pattern and did not resolve the issue").

### Knowledge Sources

The operational runbook vector store should be continuously enriched from:

| Source | Ingestion Method | Frequency |
|--------|-----------------|-----------|
| Resolved incidents (this platform) | Automatic post-verification | Real-time |
| Red Hat Knowledge Base (access.redhat.com) | API scraper + embedding pipeline | Weekly |
| Internal runbooks (Git/Confluence) | Webhook on commit/publish | On change |
| Vendor advisories (Red Hat Security) | RSS/API ingestion | Daily |
| Post-mortem reports | Manual or CI-triggered embedding | On creation |

---

## 9. Governance, Safety, and Compliance

### Change Management Integration

The current demo creates ServiceNow Incidents only. Production requires
integration with the **Change Management** module:

- Every remediation action (playbook execution) must have an associated
  **Change Request** (CR) in ServiceNow.
- The CR captures: what will change, why, rollback plan, risk assessment,
  affected CIs (from CMDB), and approval chain.
- Low-risk changes (single pod restart, node uncordon) can use a
  **Standard Change** template with pre-approval.
- High-risk changes (node drain, operator configuration, MachineConfig) require
  **Normal Change** with CAB (Change Advisory Board) or on-call approval.

### RBAC Scoping

The current demo grants `cluster-admin` to the `self-healing-sa` service
account. Production RBAC follows the principle of least privilege:

| Action Category | Required Permissions | Example |
|----------------|---------------------|---------|
| Read diagnostics | `get`, `list`, `watch` on nodes, pods, events, operators | All investigations |
| Node operations | `patch` nodes, `create` pod evictions | Uncordon, drain |
| Operator config | `patch` specific operator CRs | OAuth, MCO |
| Namespace workloads | `delete` pods, `patch` deployments in target NS | Pod restart |
| Cluster-wide config | `patch` MachineConfig, ClusterOperator | MCP remediation |

Each remediation type uses a dedicated `ServiceAccount` with only the
permissions required for that action category. The agentic AI cannot
escalate its own privileges -- it can only use tools bound to the SA of
the current workflow context.

### Blast Radius Control

Every AI-generated playbook is evaluated against a blast radius policy before
execution:

1. **Static analysis**: Parse the playbook YAML and identify all resources
   targeted (by kind, namespace, name). Compare against the allow-list.

2. **Dry-run execution**: Run the playbook with `--check` mode. Evaluate the
   "changed" count and resource types.

3. **Blast radius scoring**: Assign a score based on:
   - Number of resources affected.
   - Whether targeted resources are in critical namespaces
     (`openshift-*`, `kube-system`).
   - Whether the action is destructive (delete, drain) vs. additive (patch,
     create).

4. **Policy decision**: Compare the score against the threshold for the
   current approval level. If it exceeds the threshold, escalate to a higher
   approval tier.

### Policy Engine

An OPA (Open Policy Agent) or Gatekeeper-based policy engine validates
AI-generated playbooks:

```rego
# Deny playbooks that delete nodes
deny[msg] {
    input.tasks[_].kubernetes.core.k8s.state == "absent"
    input.tasks[_].kubernetes.core.k8s.kind == "Node"
    msg := "Playbooks must not delete Node resources directly"
}

# Deny playbooks targeting openshift-etcd namespace
deny[msg] {
    input.tasks[_].kubernetes.core.k8s.namespace == "openshift-etcd"
    msg := "Playbooks must not modify resources in openshift-etcd"
}

# Require verification task
deny[msg] {
    not has_verification_task
    msg := "Playbooks must include a verification task"
}
```

### Audit Trail

Every action taken by the self-healing platform is logged to an immutable
audit store:

| Event | What Is Logged |
|-------|---------------|
| Alert received | Alert payload, fingerprint, timestamp, EDA rule matched |
| Incident created | Incident ID, correlation group, initial state |
| AI tool call | Tool name, arguments, result (truncated), tokens used |
| Playbook generated | Full playbook YAML, blast radius score, policy evaluation |
| Approval requested | Change Request ID, approver(s), SLA deadline |
| Playbook executed | AAP job ID, start/end time, exit status, resources changed |
| Verification result | Pass/fail, before/after diagnostics diff |
| Incident resolved | Resolution record, time-to-resolution, human involvement |

The audit store should be an OpenShift-native logging pipeline (Vector +
Loki or Elasticsearch) with retention policies aligned with compliance
requirements (typically 1-7 years for SOC 2 / ISO 27001).

---

## 10. Multi-Cluster and Multi-Tenant Scale

### Current Limitation

The demo operates on a single OpenShift cluster. The EDA rulebook, AAP
workflow, AI model, and incident registry are all deployed on the same
cluster they monitor. This is a single point of failure and does not scale
to fleet management.

### Multi-Cluster Architecture with ACM

```
┌───────────────────────────────────────────┐
│          Hub Cluster (ACM)                │
│                                           │
│  ┌─────────────────────┐                  │
│  │ AAP Controller      │                  │
│  │ (centralized)       │                  │
│  │                     │                  │
│  │ EDA Controller      │                  │
│  │ (centralized)       │                  │
│  └─────────┬───────────┘                  │
│            │                              │
│  ┌─────────┴───────────┐                  │
│  │ OpenShift AI        │                  │
│  │ (centralized model  │                  │
│  │  serving)           │                  │
│  └─────────────────────┘                  │
│                                           │
│  ┌─────────────────────┐                  │
│  │ Incident Registry   │                  │
│  │ Knowledge Base      │                  │
│  │ (shared across      │                  │
│  │  fleet)             │                  │
│  └─────────────────────┘                  │
│                                           │
└──────────┬──────────┬──────────┬──────────┘
           │          │          │
     ┌─────┘     ┌────┘     ┌───┘
     ▼           ▼          ▼
┌─────────┐ ┌─────────┐ ┌─────────┐
│Managed  │ │Managed  │ │Managed  │
│Cluster 1│ │Cluster 2│ │Cluster 3│
│         │ │         │ │         │
│Thanos   │ │Thanos   │ │Thanos   │
│Sidecar  │ │Sidecar  │ │Sidecar  │
│ +       │ │ +       │ │ +       │
│Alert    │ │Alert    │ │Alert    │
│Forwarder│ │Forwarder│ │Forwarder│
└─────────┘ └─────────┘ └─────────┘
```

Design decisions:

- **Centralized AI and KB**: The LLM and knowledge base are shared across
  all managed clusters. This allows cross-cluster learning (a resolution
  discovered on Cluster 1 is immediately available for Cluster 2).

- **Centralized EDA + AAP**: The hub cluster runs EDA and AAP Controller.
  Managed clusters forward alerts to the hub via ACM's Observability
  component (Thanos federation) and Alertmanager remote-write.

- **Distributed execution**: Remediation playbooks execute on the target
  cluster via AAP's credential and inventory model. Each managed cluster
  has its own `Machine` credential in AAP, and the workflow selects the
  correct one based on the alert's `cluster` label.

- **Cluster identity**: Every alert must carry a `cluster` label identifying
  the source cluster. ACM's alert forwarding adds this automatically.

### Tenant Isolation

In multi-tenant environments (shared clusters or managed service providers):

- **Namespace-scoped incidents**: Each tenant's alerts map to a dedicated
  ITSM queue and approval chain.
- **RBAC per team**: The self-healing SA for tenant A cannot access tenant B's
  namespaces.
- **Separate knowledge bases**: Tenant-specific resolutions are isolated.
  Shared infrastructure resolutions (node, operator) are in a global KB.
- **Blast radius boundaries**: Remediation for tenant A cannot affect
  resources outside tenant A's namespace quota.

---

## 11. Integration Maturity

### ServiceNow Enhancement

| Capability | Demo | Production |
|-----------|------|------------|
| **Module** | Incident only | Incident + Change Management + Problem + CMDB |
| **Authentication** | Basic auth (service accounts) | OAuth 2.0 with scoped app registration |
| **CMDB** | Not used | Map alerts to Configuration Items (CIs) via `cmdb_ci` field |
| **Problem Management** | Not used | Auto-create Problem records for recurring alert patterns |
| **Assignment** | Fixed service accounts | Assignment rules based on CI ownership and on-call schedule |
| **SLA tracking** | Not used | Track response and resolution SLAs per priority |

### Security Hardening

The demo has multiple `validate_certs: false` flags and basic auth patterns
that are acceptable for lab environments but must be addressed for production:

| Current | Production |
|---------|-----------|
| `validate_certs: false` on LlamaStack, Gitea, AAP Controller | TLS with cluster CA trust chain; all internal services use OpenShift service serving certificates |
| Basic auth for Gitea API | OAuth 2.0 or OpenShift SA token authentication |
| Basic auth for AAP Controller API | OAuth 2.0 token via AAP's built-in OAuth provider |
| ServiceNow basic auth | OAuth 2.0 with client credentials grant |
| Shared `cluster-admin` SA | Per-action SAs with minimal RBAC (see Section 9) |
| Cleartext credentials in env vars | HashiCorp Vault or AAP Credential lookups with external secret management |

### Observability Stack

End-to-end visibility from alert to resolution:

| Layer | Tool | What It Shows |
|-------|------|---------------|
| **Metrics** | Prometheus + Grafana | Self-healing KPIs: MTTR, auto-resolution rate, AI accuracy, alert-to-workflow latency |
| **Traces** | OpenTelemetry + Jaeger/Tempo | Full trace from alert ingestion through EDA, workflow steps, AI iterations, to resolution |
| **Logs** | Vector + Loki | Structured logs from all components, correlated by incident ID |
| **Dashboards** | Grafana | Real-time operational dashboard showing active incidents, resolution pipeline, model performance |

Key metrics to track:

| Metric | Description | Target |
|--------|-------------|--------|
| `self_healing_alerts_ingested_total` | Raw alerts received by the filtering pipeline | Trending |
| `self_healing_alerts_filtered_total` | Alerts discarded by severity gate or dedup (by reason) | >70% of ingested |
| `self_healing_incidents_total` | Total incidents created (by category, severity) | Trending |
| `self_healing_auto_resolved_total` | Incidents resolved without human intervention | >70% of eligible |
| `self_healing_mttr_seconds` | Mean time from alert to verified resolution | <10 minutes |
| `self_healing_escalation_rate` | Percentage of incidents requiring human escalation | <30% |
| `self_healing_false_positive_rate` | Unnecessary remediations / total remediations | <5% |
| `self_healing_ai_rca_accuracy` | Correct RCA / total RCAs (sampled, human-labeled) | >85% |
| `self_healing_playbook_success_rate` | Playbooks that pass post-remediation verification | >80% |
| `self_healing_kb_hit_rate` | Incidents matched to known resolutions | Increasing over time |

---

## Summary: Current vs. Production Maturity Matrix

| Dimension | Demo (Current) | Production (Target) |
|-----------|---------------|-------------------|
| **Alert coverage** | 6 rules, 4 scenarios | Universal handler, any alert |
| **EDA triggers** | Per-alert rules with `alertname` match | Single generic rule with AI classification |
| **Pre-AI filtering** | None (all matched alerts hit the workflow) | AMQ Streams pipeline: severity gate, dedup, correlation window -- 70-90% noise reduction before AI |
| **Deduplication** | `once_within: 3 hours` timer | Stateful incident registry with correlation engine |
| **Alert suppression** | None during remediation | Two-layer gate (EDA filter + workflow check) |
| **AI interaction** | Single prompt/response | Agentic ReAct loop with tool calling |
| **AI model** | Mistral Small 3.1 24B (single L4) | Granite 3.1 34B+ with tool-use (multi-GPU) |
| **Knowledge base (routing)** | Exact JT name match | Vector similarity with confidence scoring |
| **Knowledge base (learning)** | JT existence in AAP | Automatic embedding of verified resolutions |
| **RAG sources** | Lightspeed (OCP docs) + static runbooks | + incident memory + RH KB + post-mortems |
| **Approval gates** | None | Policy-driven per severity/blast-radius |
| **Post-remediation verification** | None | Automated before/after comparison |
| **Governance** | `cluster-admin` SA | Per-action RBAC + policy engine + audit trail |
| **ITSM** | Incident only (basic auth) | Incident + Change + Problem + CMDB (OAuth) |
| **Scale** | Single cluster | Multi-cluster via ACM hub-spoke |
| **Observability** | AAP job output | OpenTelemetry traces + Grafana dashboards + KPI metrics |

---

## References

- [Red Hat AMQ Streams 2.8 -- Deploying and Managing AMQ Streams on OpenShift](https://docs.redhat.com/en/documentation/red_hat_amq_streams/2.8/html/deploying_and_managing_amq_streams_on_openshift/index)
- [Red Hat Ansible Automation Platform 2.5 -- Event-Driven Ansible](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.5/html/using_event-driven_ansible_automation/index)
- [Red Hat OpenShift AI 3.3 -- Serving Models](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/serving_models/index)
- [Red Hat OpenShift Lightspeed 1.0 -- Cluster Interaction](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html-single/configure/index#about-cluster-interaction)
- [LlamaStack -- Tool Use and Agents](https://llama-stack.readthedocs.io/en/latest/building_applications/tools.html)
- [Red Hat Advanced Cluster Management 2.12 -- Observability](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.12/html/observability/index)
- [ServiceNow -- Change Management](https://docs.servicenow.com/bundle/latest/page/product/change-management/concept/c_ITILChangeManagement.html)
- [IBM Granite Models -- Red Hat Model Catalog](https://catalog.redhat.com/search?searchType=ai-models)
- [ReAct: Synergizing Reasoning and Acting in Language Models](https://arxiv.org/abs/2210.03629) (Yao et al., 2022)
