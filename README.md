# AWS EKS Platform — a production-shaped Kubernetes app on AWS

> **Sep 2026:** both drill findings fixed — preStop drain + readiness 503 on SIGTERM + 15 s deregistration delay; CPU work in a child process with separate liveness/readiness/startup probes; PDB; kubeconform + manifest policy CI; runtime image without pip (validated, not re-drilled).

Running a containerized microservice on **Amazon EKS** the way a real team would:
provisioned entirely in **Terraform**, exposed through an **ALB Ingress**,
**auto-scaled** on load, deployed by a **keyless GitHub Actions pipeline**, and
proven resilient with a **pod-failure drill**.

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

## v2 (Sep 2026) — the drill findings, fixed and pinned

The 2026-07-12 run was honest about two things a happy-path demo hides. Both are now fixes, with a CI policy check so they can't regress:

| Finding | Fix |
| --- | --- |
| **3 of 400 requests got 502** while a pod was replaced — the ALB kept routing to the terminating pod (default deregistration delay is 300 s; the pod was gone long before). | Three parts that agree with each other: the app flips **`/ready` to 503 on SIGTERM** while still serving; a **`preStop` sleep of 15 s** keeps the pod alive while the ALB deregisters it; the Ingress sets **`deregistration_delay = 15 s`** and health-checks `/ready`; `terminationGracePeriodSeconds: 45` so nothing is force-killed mid-drain. |
| **A pod restarted under load** — its liveness probe timed out at the default 1 s while `/burn`'s pure-Python busy loop held the GIL. | `/burn` runs in a **child process**, so the API process (and its probe) stays responsive; liveness (`/healthz`) and readiness (`/ready`) are **separate endpoints**; the liveness probe has a 3 s timeout and 3 misses; a `startupProbe` covers cold start. A test starts a 1.5 s burn and asserts `/healthz` answers in under 0.5 s. |

Also: a **PodDisruptionBudget** (`minAvailable: 1`) so node drains can't evict below one replica, `revisionHistoryLimit`, structured JSON access logs with the pod name, API docs disabled, and a CI workflow — pytest, **kubeconform strict** validation, a **manifest policy check** (preStop present, grace > sleep, distinct probe endpoints, deregistration delay matching, PDB present), `terraform validate`, and an image build with a non-root assertion and Trivy.

The cluster is torn down (build → prove → destroy), so the fixes are validated, not re-drilled; re-running the self-heal drill to confirm 0 of 400 is the next live session.

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
terraform/      VPC, EKS, node group, IRSA, ALB controller, addons
k8s/ | chart/   Kubernetes manifests / Helm chart (Deployment, Service, Ingress, HPA)
.github/        OIDC-authenticated build + deploy pipeline
docs/           architecture, cost model, runbook, drill results
iam/            OIDC trust + deploy policy (committed for transparency)
```

## Not affiliated with AWS — a personal learning + portfolio project by
[Rajolu Abheenash](https://abheenash.com).
