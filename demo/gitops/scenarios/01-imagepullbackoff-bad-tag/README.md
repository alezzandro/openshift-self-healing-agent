# Scenario: ImagePullBackOff from a bad GitOps image tag

OpenShift GitOps (Argo CD) syncs a CNF-like sample app whose Git source
declares a container image tag that does not exist. Pods in
`cnf-gitops-demo` stick in `ImagePullBackOff`, Prometheus fires
`DemoCNFImagePullBackOff`, and the self-healing workflow produces RCA plus a
**git-fix** Job Template. The first run is operator-approved; the second run
auto-executes the same template. The live Deployment is never patched —
Argo CD remains the reconciler.

## Demo Layer

**GitOps CNF delivery** -- post-deploy failure intelligence (customer UC2).
The source of truth is the Gitea `cnf-sample` repository; OpenShift GitOps
Application `cnf-sample` syncs it into namespace `cnf-gitops-demo`.

## Alert

| Field | Value |
|-------|-------|
| Alert name | `DemoCNFImagePullBackOff` |
| Severity | `warning` |
| Key labels | `namespace=cnf-gitops-demo`, `pod`, `container` |
| Default `for` | **1 minute** (demo PrometheusRule override) |

## What Happens

1. `trigger.sh` updates `deployment.yaml` in Gitea repo `cnf-sample` to
   `registry.access.redhat.com/ubi9/httpd-24:vf-demo-bad-tag` via the Gitea
   Contents API.
2. The script annotates Argo CD Application `cnf-sample` with
   `argocd.argoproj.io/refresh=hard` so the bad revision is pulled promptly.
3. The new ReplicaSet cannot pull the image; a pod shows `ImagePullBackOff`
   (often after a brief `ErrImagePull`).
4. After ~1 minute Prometheus fires `DemoCNFImagePullBackOff`. Alertmanager
   webhooks Event-Driven Ansible, which starts `self-healing-workflow`.
5. Diagnostics include Argo Application status, the live Deployment image,
   and failing pods. AI RCA lands in ServiceNow. The workflow attaches the
   golden playbook that restores
   `registry.access.redhat.com/ubi9/httpd-24:latest` in Git.
6. **First run:** the operator reviews and launches
   `Remediate DemoCNFImagePullBackOff`. The JT commits the good image to
   Gitea; Argo CD syncs; pods become Running.
7. **Second run:** after `reset-eda.sh` (throttle only), trigger again. The
   knowledge base matches; the same JT auto-launches; Git and Argo heal
   without a second approval.

## Why This Matters

Image pull failures after a GitOps sync are a realistic CNF delivery
incident: a bad tag, a registry outage, or a promotion of the wrong digest.
Live-patching the Deployment would fight Argo CD self-heal and hide the
source of truth. The agent keeps Git as source of truth, explains the
failure with cluster + Argo context, and remediates with Ansible against
Gitea so OpenShift GitOps reconciles the fix.

See [Red Hat OpenShift GitOps](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/)
and [OpenShift Container Platform monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/monitoring/index).

## Demo Script

### 1. Set the stage (~30s)

> "This cluster delivers a sample CNF through Red Hat OpenShift GitOps.
> Argo CD Application `cnf-sample` syncs from Gitea. If Git declares a tag
> the registry does not have, the workload fails *after* sync — that is
> post-deployment failure intelligence, not a pre-deploy gate."

Show healthy state:

```bash
oc get application cnf-sample -n openshift-gitops
oc get pods -n cnf-gitops-demo
```

Optionally open **Argo CD UI** (URL from `./setup/show-credentials.sh`) and
confirm Application `cnf-sample` is Synced / Healthy.

### 2. Trigger the failure (~1 min)

```bash
./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/trigger.sh
```

Walk through the three steps (Gitea commit, Argo hard refresh, wait for
`ImagePullBackOff`). Confirm in Argo CD that pods are failing, then in
**Gitea** that `deployment.yaml` now references `vf-demo-bad-tag`.

### 3. Watch the alert fire (~1–2 min)

Switch to **OpenShift Console** > Observe > Alerting.
`DemoCNFImagePullBackOff` should fire about **1 minute** after
`ImagePullBackOff` (`for: 1m`). Budget ~2–3 minutes end-to-end from trigger.

> "Prometheus is watching kube state in `cnf-gitops-demo`, not scraping the
> app. The alert is the same class of signal we already route to EDA."

### 4. Watch EDA and the workflow (~2–4 min)

**AAP UI** > Event-Driven Ansible > Rule Audit, then **Jobs**:

- **Gather diagnostics:** Argo Application `cnf-sample`, Deployment image,
  failing pods / pull errors.
- **ServiceNow:** new INC with diagnostics.
- **Knowledge base:** first run = no match.
- **AI RCA:** Git is source of truth; Argo synced a bad tag; do not
  live-patch.
- **Store resolution** and create Job Template
  `Remediate DemoCNFImagePullBackOff`.

> "The RCA tells the operator to approve a git-fix. Argo CD will sync the
> restored UBI image. We are not `oc set image` on the live Deployment."

### 5. First run — approve the Job Template (~1–2 min)

In **AAP** > Templates, launch `Remediate DemoCNFImagePullBackOff`
(or follow the ServiceNow work-note instructions).

Then show:

1. **Gitea** `cnf-sample` — new commit restoring
   `registry.access.redhat.com/ubi9/httpd-24:latest`.
2. **Argo CD** — Application returns to Synced / Healthy.
3. **Pods** — `Running` in `cnf-gitops-demo`.

```bash
oc get pods -n cnf-gitops-demo
oc get application cnf-sample -n openshift-gitops
```

### 6. Learning loop — second run (~3–5 min)

Do **not** wipe the knowledge base or delete the Job Template.

```bash
./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/reset-eda.sh
./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/trigger.sh
```

`reset-eda.sh` only restarts the EDA activation so the 3-hour
`once_within` throttle does not swallow the second alert.

This time Step 3 matches the stored resolution and **auto-launches** the
same JT. Git is fixed again; Argo heals without a second approval.

> "First occurrence is human-reviewed. Recurrence is automatic — still
> through Git, still through Argo CD."

If throttle still blocks, remind the audience and re-run `reset-eda.sh`.

## Expected Outcome

- First run: RCA in ServiceNow, JT created, operator launch restores Git,
  Argo CD syncs, pods Running.
- Second run: KB hit, auto JT, same git path, no second approval.
- `cnf-sample` source of truth ends on
  `registry.access.redhat.com/ubi9/httpd-24:latest`.

## Cleanup

```bash
./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/cleanup.sh
```

Restores the good image in Gitea, refreshes Argo CD, and waits for the
Deployment to become Available. If a re-demo is blocked by EDA throttle:

```bash
./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/reset-eda.sh
```

Or reset the full environment (this **does** wipe demo JTs / KB re-index):

```bash
./setup/reset-demo.sh
```
