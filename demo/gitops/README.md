# GitOps Demo Track

Post-deployment GitOps failure intelligence on **Red Hat OpenShift** using
**Red Hat OpenShift GitOps** (Argo CD). A sample CNF-like app (`cnf-sample`)
is synced from Gitea. A bad image tag produces `ImagePullBackOff`; the
existing Prometheus → Alertmanager → EDA → AAP → Lightspeed/LlamaStack →
ServiceNow loop returns a **git-fix** Job Template. Argo CD remains the
reconciler.

This is the Customer GitOps use-case presenter path. Infrastructure Day-2
scenarios remain under `demo/infrastructure/`.

**Prerequisite:** `./setup/09-configure-gitops.sh` (and the rest of
`./setup/full-setup.sh`). URLs: `./setup/show-credentials.sh`.

## Scenario

| # | Folder | Alert | Failure |
|---|--------|-------|---------|
| 1 | `scenarios/01-imagepullbackoff-bad-tag/` | `DemoCNFImagePullBackOff` | Bad UBI httpd tag in Git |

- **Good image:** `registry.access.redhat.com/ubi9/httpd-24:latest`
- **Bad image:** `registry.access.redhat.com/ubi9/httpd-24:demo-bad-tag`
- **Repo / Argo app:** `cnf-sample`
- **Namespace:** `cnf-gitops-demo`

Full presenter script: [`scenarios/01-imagepullbackoff-bad-tag/README.md`](scenarios/01-imagepullbackoff-bad-tag/README.md).

Product docs: [Red Hat OpenShift GitOps](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/).

## Walkthrough (timings)

Budget **~10–12 minutes** for first run + learning loop (alert `for:` is 1
minute; allow 2–3 minutes from trigger to firing alert).

### 1. Healthy GitOps delivery (~30s)

```bash
oc get application cnf-sample -n openshift-gitops
oc get pods -n cnf-gitops-demo
```

Open **Argo CD** (route in `./setup/show-credentials.sh`) → Application
`cnf-sample` → Synced / Healthy. Optionally show Gitea repo `cnf-sample`
`deployment.yaml` on `:latest`.

> "Git is the source of truth. OpenShift GitOps applies what Git declares.
> If the tag is wrong, the cluster fails *after* a successful sync."

### 2. Break Git (~1 min)

```bash
./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/trigger.sh
```

Confirm `ImagePullBackOff` in Argo CD (failed pods) and
`oc get pods -n cnf-gitops-demo`.

### 3. Alert → EDA → workflow (~2–3 min)

| UI | What to click |
|----|----------------|
| OpenShift Console > Observe > Alerting | `DemoCNFImagePullBackOff` firing |
| AAP > Event-Driven Ansible > Rule Audit | webhook matched, workflow launched |
| AAP > Jobs | diagnostics include Argo + pull errors |
| ServiceNow | INC + RCA (Git + Argo `cnf-sample`; do not live-patch) |
| AAP > Templates | `Remediate DemoCNFImagePullBackOff` created |

### 4. First run: approve JT (~1–2 min)

Launch the Job Template. Then:

1. **Gitea** `cnf-sample` — commit restores `:latest`.
2. **Argo CD** — Application Healthy.
3. **Pods** — Running.

### 5. Second run: learning loop (~3–5 min)

Keep the knowledge base and the Job Template. Clear only EDA throttle:

```bash
./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/reset-eda.sh
./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/trigger.sh
```

Expect KB match and **auto** JT launch. Same git commit → Argo sync → healthy
pods, no second approval.

### 6. Cleanup

```bash
./demo/gitops/scenarios/01-imagepullbackoff-bad-tag/cleanup.sh
```

If throttle blocks a re-demo, run `reset-eda.sh` again. Full environment
reset (wipes demo JTs and re-indexes KB): `./setup/reset-demo.sh`.

## Talking points

- **Source of truth stays Git.** Remediation commits to Gitea; Argo CD
  syncs. Live `oc patch` / `oc set image` would be reverted by self-heal.
- **Human first, automatic second.** First `DemoCNFImagePullBackOff` is
  reviewed; recurrence reuses the proven JT.
- **Same closed loop as infra.** Only the trigger (bad Git revision) and
  the fix (git-fix playbook) changed.
- **Alert timing.** Demo `for: 1m` — say “about a minute after pull
  backoff,” not the production default.
