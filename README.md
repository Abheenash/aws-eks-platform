# AWS EKS Platform — a production-shaped Kubernetes app on AWS

Running a containerized microservice on **Amazon EKS** the way a real team would:
provisioned entirely in **Terraform**, node capacity from **Karpenter** on Spot, IAM
through **EKS Pod Identity**, deployed by **Argo CD** so CI never holds cluster-admin,
and observed with **Prometheus** burn-rate alerts.

### The 30-second version

An EKS control plane bills ~$0.10/hr for as long as it exists, so this project runs a
**build → prove → destroy** loop rather than leaving a cluster up. The cluster is currently
destroyed — which means the Terraform here is *validated, not applied*, and the README says
so everywhere rather than implying otherwise.

The Kubernetes layer is proven a different way: **on a local kind cluster, which is free.**
That is not a substitute for EKS and the write-up says what it cannot cover. It is, however,
a real API server and real kubelets — and running the manifests against it found **five bugs
that `terraform validate`, `kubeconform` and checkov all pass**:

| Found by running it | Why nothing else caught it |
|---|---|
| `WebNoTraffic` could never fire | `sum(rate(...)) == 0` is empty, not zero, once the app's metrics go stale — so the alert written to catch total silence stops evaluating in exactly that outage |
| The error-budget rule returned nothing instead of `0` | Same trap: summing no series yields an empty result, and the SLO panel shows a gap where it should show a flat zero line |
| `app_build_info` carried a colliding `pod` label | Service discovery attaches its own, so Prometheus renamed mine to `exported_pod` — queries then match one or the other, never reliably both |
| The pod mounted a service-account token it never used | No Kubernetes client in `requirements.txt`; the token was pure upside for anyone getting code execution |
| My first NetworkPolicy allowed **every** source | An ingress rule with `ports` and no `from` reads like "allow this port" and means "allow this port from anywhere" |

Measured, not asserted: a rolling deploy served **40/40** requests and a node drain **100/100**,
while force-killing every replica at once still cost **~2 s and 7 failed requests** — the
counter-test is in the write-up too, because a drill that only runs the cases you expect to
pass is not a drill.

**→ [`docs/drills/2026-09-24-kind-cluster.md`](docs/drills/2026-09-24-kind-cluster.md)** is the
thing worth reading.

<details>
<summary><b>Version history</b></summary>


> **Sep 2026 (v5):** the Kubernetes layer **run for real on local kind clusters** — free,
> no AWS. Prometheus discovery, every alert expression, a rolling deploy, a hard kill of
> every replica, a node drain, the HPA and the NetworkPolicies were all exercised against a
> real API server and real kubelets. It found five bugs that `terraform validate`,
> `kubeconform` and checkov all pass: `WebNoTraffic` could never fire (an empty vector is
> not zero), the error-budget recording rule returned nothing instead of 0, `app_build_info`
> exported a `pod` label that collided with the one service discovery attaches, the pod
> mounted a service-account token for an API server it never talks to, and the first
> NetworkPolicy I wrote allowed every source instead of one — an ingress rule with `ports`
> and no `from`. All fixed and re-verified.
> Measured numbers in [`docs/drills/2026-09-24-kind-cluster.md`](docs/drills/2026-09-24-kind-cluster.md).
>
> **Sep 2026 (v4):** **Prometheus + Grafana** on the cluster — kube-prometheus-stack, a ServiceMonitor, multi-window burn-rate PrometheusRules, and a Grafana dashboard provisioned from version-controlled JSON. The app now exports metrics labelled by matched ROUTE, not raw path, with a test that fires 25 distinct 404s and asserts exactly one series. Plus an OpenShift port. `terraform validate` clean; not applied.
>
> **Sep 2026 (v3 — modernisation):** EKS 1.31 → **1.35** (1.31 left standard support 2025-11-25 and was billing extended-support), EKS module 20 → **21**, **Karpenter** with Spot + consolidation replacing fixed node-group scaling, **EKS Pod Identity** replacing IRSA, **Argo CD** app-of-apps so CI no longer holds cluster-admin, AWS provider 5 → **6**, helm provider 2 → **3**, plus an **OpenShift port** of the workload with the SCC differences written up. `terraform validate` clean; not re-applied.
>
> **Sep 2026:** both drill findings fixed — preStop drain + readiness 503 on SIGTERM + 15 s deregistration delay; CPU work in a child process with separate liveness/readiness/startup probes; PDB; kubeconform + manifest policy CI; runtime image without pip (validated, not re-drilled).

</details>

---

This is the *"can you run Kubernetes on AWS?"* project — the day-to-day platform
skill most Cloud/DevOps roles ask for, on top of the serverless, container,
IaC, CI/CD, observability, and security work in my other repos.

**Status:** ✅ **All stages complete — applied live and proven, then destroyed.**
A real `apply → deploy → drills → destroy` burst on 2026-07-12 stood up the cluster
(66 resources), ran both resilience drills with **measured** evidence (pod self-heal
in 7s; HPA scaled 2→6 in ~60s), and tore everything down. Full numbers +
honest findings in [`docs/RESULTS-2026-07-12.md`](docs/RESULTS-2026-07-12.md).

> **Cost & operating model.** An EKS control plane bills ~$0.10/hr **the whole
> time it exists**, unlike a fully free-tier serverless stack — so this project
> follows a deliberate **build → prove → destroy** loop: stand it up, capture real
> evidence (cluster up, ALB serving, HPA scaling, a pod self-healing), then
> `terraform destroy`. A full build-and-demo burst is ~$0.50–1. The Terraform
> makes it reproducible on demand for interviews. Cost breakdown in
> [`docs/cost.md`](docs/cost.md).

## v3 (Sep 2026) — paying down a year of drift

The v2 cluster was correct when it was built and quietly went stale: **EKS 1.31 left
standard support on 2025-11-25**, so the cluster had moved onto extended support and was
billing $0.60/cluster/hour for the privilege. That is the honest reason this version exists —
infrastructure rots even when nobody touches it, and noticing is the job.

| Area | v2 | v3 | Why it matters |
| --- | --- | --- | --- |
| **Kubernetes** | 1.31 (extended support, paid) | **1.35** (standard support) | Stops the extended-support charge and gets security patches again |
| **EKS module** | `~> 20.24` | **`~> 21.0`** | `cluster_name`→`name`, `cluster_version`→`kubernetes_version`, `cluster_addons`→`addons`; IRSA helpers removed |
| **Workload IAM** | IRSA (OIDC trust policy per service account) | **EKS Pod Identity** | No per-cluster OIDC provider, no issuer URL baked into the trust policy — the role survives a cluster rebuild unchanged |
| **Node capacity** | fixed managed node group, ON_DEMAND, one instance type | **Karpenter** — instance type chosen per pending pod, Spot-first, `WhenEmptyOrUnderutilized` consolidation, 14-day node expiry | A fixed ASG can only scale a shape someone guessed in advance; Karpenter also deletes nodes it no longer needs, which is where the cost actually falls |
| **Delivery** | CI runs `kubectl apply` + `set image` | **Argo CD app-of-apps**; CI writes the image tag to git and pushes | CI no longer holds cluster-admin. The cluster pulls its own desired state, and `selfHeal`/`prune` make drift impossible to leave behind |
| **Providers** | aws `~> 5.60`, helm `~> 2.14` | **aws `~> 6.0`, helm `~> 3.0`** | helm v3 moved to the plugin framework: `kubernetes` is an object attribute and `set` is a list, not repeated blocks |
| **Staying current** | nothing | **Renovate + pre-commit + tflint** | The drift above went unnoticed for a year. This is the part that makes v4 unnecessary |

### What Karpenter and Argo CD actually changed

The `system` managed node group is deliberately kept — it is where Karpenter's own
controller runs, so the component that creates nodes never depends on a node it created.
Everything else lands on Karpenter capacity: `cluster/karpenter-nodepool.yaml` allows
`c`/`m`/`t` families from generation 5 up, Spot first, with a 16-vCPU ceiling.

Argo CD inverts the delivery direction. `gitops/root-app` is one Application pointing at
`gitops/apps/`, so adding a workload is a file in git — no `terraform apply`, no `kubectl`.
The deploy workflow's only remaining job is to build the image and rewrite one `image:` line;
the commit *is* the deployment. It needs no AWS credentials and no cluster access.

### Observability: the other stack

[`docs/observability.md`](docs/observability.md) is the companion to
`cloud-observability-sre`: the same golden signals and the same SLO, answered
with **Prometheus and Grafana** instead of CloudWatch. Three things genuinely
differ — pull-based discovery (and why `serviceMonitorSelectorNilUsesHelmValues`
is the reason your service "isn't being scraped"), histogram buckets as a
decision you make *before* you need the percentile, and cardinality as an
availability risk rather than a cost line.

That last one is why the middleware labels by **matched route template** and
collapses everything else to `unmatched`, and why `tests/test_metrics.py` fires
25 distinct 404s and asserts exactly one series comes out.

### Running it somewhere that isn't EKS

[`openshift/`](openshift/) is the same workload under OpenShift, and
[`docs/openshift.md`](docs/openshift.md) is the porting write-up. The short
version: OpenShift's `restricted-v2` SCC injects an arbitrary UID per namespace,
so `runAsUser: 10001` gets the pod rejected outright — and that one constraint
cascades into image ownership, `HOME`, and anything that calls `getpwuid()`.
Ingress becomes a Route and the Service drops from NodePort to ClusterIP.

What *didn't* change is the interesting half: both probes, the 15-second `preStop`
and the 45-second grace period — the fix for the drill finding below — port
unaltered, because that was never an ALB problem.

Manifests only; I have no OpenShift cluster and the doc says so rather than
implying otherwise.

> **Status:** `terraform validate` clean against the real modules (EKS 21.26.0, VPC 6.7.3,
> pod-identity 2.9.0, AWS provider 6.66.0). **Not re-applied** — the drill numbers quoted
> below are still v2's, measured on 2026-07-12. The v3 cluster has not been stood up, so
> nothing here claims measured evidence it doesn't have.

## v2 (Sep 2026) — the drill findings, fixed and pinned

The 2026-07-12 run was honest about two things a happy-path demo hides. Both are now fixes, with a CI policy check so they can't regress:

| Finding | Fix |
| --- | --- |
| **3 of 400 requests got 502** while a pod was replaced — the ALB kept routing to the terminating pod (default deregistration delay is 300 s; the pod was gone long before). | Three parts that agree with each other: the app flips **`/ready` to 503 on SIGTERM** while still serving; a **`preStop` sleep of 15 s** keeps the pod alive while the ALB deregisters it; the Ingress sets **`deregistration_delay = 15 s`** and health-checks `/ready`; `terminationGracePeriodSeconds: 45` so nothing is force-killed mid-drain. |
| **A pod restarted under load** — its liveness probe timed out at the default 1 s while `/burn`'s pure-Python busy loop held the GIL. | `/burn` runs in a **child process**, so the API process (and its probe) stays responsive; liveness (`/healthz`) and readiness (`/ready`) are **separate endpoints**; the liveness probe has a 3 s timeout and 3 misses; a `startupProbe` covers cold start. A test starts a 1.5 s burn and asserts `/healthz` answers in under 0.5 s. |

Also: a **PodDisruptionBudget** (`minAvailable: 1`) so node drains can't evict below one replica, `revisionHistoryLimit`, structured JSON access logs with the pod name, API docs disabled, and a CI workflow — pytest, **kubeconform strict** validation, a **manifest policy check** (preStop present, grace > sleep, distinct probe endpoints, deregistration delay matching, PDB present), `terraform validate`, and an image build with a non-root assertion and Trivy.

The cluster is torn down (build → prove → destroy), so these fixes were validated but not re-drilled on EKS. They have since been re-drilled **locally on kind**, which exercises the same manifests against a real API server and real kubelets for nothing: a rolling restart served 40 of 40 requests, and a node drain served 100 of 100. See [`docs/drills/2026-09-24-kind-cluster.md`](docs/drills/2026-09-24-kind-cluster.md) — including the honest counter-test, where force-killing every replica at once still cost ~2 s of downtime, because no manifest can prevent that.

## Why this project

My portfolio already shows **build → ship → operate** across serverless and
containers. The consistent gap for a DevOps target is **Kubernetes** — it's a
gate in a large share of job postings. This project fills it with a real EKS
platform, not a toy: infrastructure as code, ingress, autoscaling, GitOps-style
CI/CD, and a resilience drill that produces measured evidence.

## Target architecture

```
GitHub Actions (OIDC, no keys)
        │  build image → ECR → deploy to EKS
        ▼
┌──────────────────────────── AWS ────────────────────────────┐
│  VPC (public + private subnets)                              │
│                                                              │
│  Internet → ALB  ──(AWS Load Balancer Controller)──►         │
│                 Kubernetes Ingress                           │
│                      │                                       │
│                 Service (ClusterIP)                          │
│                      │                                       │
│            ┌─────────┴─────────┐   Amazon EKS                │
│            ▼         ▼         ▼   (managed control plane)   │
│          Pod       Pod       Pod   ← Horizontal Pod          │
│         (app)     (app)     (app)     Autoscaler on CPU      │
│                                                              │
│   Managed node group (EC2)  ·  IRSA (IAM Roles for SAs)      │
│   Metrics Server  ·  CloudWatch Container Insights           │
└──────────────────────────────────────────────────────────────┘
```

## Roadmap

- [x] **Stage 0 — Foundation.** Repo + this plan committed first; reused the
  existing GitHub OIDC provider; created a repo-scoped deploy role + ECR repo.
- [x] **Stage 1 — The app.** Containerized FastAPI microservice (`/health`, `/`
  reports the serving pod, `/burn` drives CPU) + hardened Kubernetes manifests.
- [x] **Stage 2 — EKS in Terraform.** VPC, EKS cluster + managed node group,
  IRSA/OIDC, EKS access entry for CI. `validate`-clean.
- [x] **Stage 3 — Platform layer.** AWS Load Balancer Controller (IRSA) → ALB
  Ingress; Metrics Server; a CPU Horizontal Pod Autoscaler (2→6).
- [x] **Stage 4 — CI/CD.** GitHub Actions builds the image → ECR → deploys over
  OIDC (no static keys), and skips cleanly when the cluster is destroyed.
- [x] **Stage 5 — Operate & prove.** ✅ *Executed live 2026-07-12:* a
  **pod-failure drill** (self-heal in 7s; honest 3/400 failed requests during
  ALB deregistration) and an **HPA load test** (scaled 2→6 in ~60s). Evidence in
  [`docs/runbook-and-drills.md`](docs/runbook-and-drills.md) +
  [`docs/RESULTS-2026-07-12.md`](docs/RESULTS-2026-07-12.md). Then `terraform destroy`.

## Design decisions (recorded as I go)

| Decision | Why |
|---|---|
| **Terraform, not `eksctl`** | One IaC tool across the whole portfolio; the cluster, addons, and app all live in code and are reviewable in a PR. |
| **Managed node group (EC2), not Fargate-only** | Shows real node/capacity and autoscaling concerns — the day-2 story Fargate hides. |
| **AWS Load Balancer Controller → ALB** | The standard, production way to expose services on EKS; ties into the ALB skills from my other projects. |
| **IRSA for pod permissions** | Pods get scoped IAM via their service account — least privilege, no node-wide credentials. |
| **Build → prove → destroy** | EKS control plane bills hourly; disciplined teardown keeps a learning/demo project at ~$1, reproducible on demand. |

## Repository layout (as it fills in)

```
app/            small containerized microservice + Dockerfile
terraform/      VPC, EKS, system node group, Karpenter, Pod Identity, ALB controller, Argo CD
k8s/            namespaced workload manifests (Deployment, Service, Ingress, HPA, PDB)
                — the path Argo CD's `web` Application syncs into the demo namespace
cluster/        cluster-scoped manifests (Karpenter EC2NodeClass + NodePool), kept out
                of k8s/ so the namespaced Application never tries to namespace them
gitops/         Argo CD app-of-apps: root-app/ is the root chart, apps/ holds one
                Application per workload — add a file here, no terraform apply
.github/        OIDC build pipeline; the deploy job writes the image tag to git
docs/           architecture, cost model, runbook, drill results
iam/            OIDC trust + deploy policy (committed for transparency)
```

## Not affiliated with AWS — a personal learning + portfolio project by
[Rajolu Abheenash](https://abheenash.com).
