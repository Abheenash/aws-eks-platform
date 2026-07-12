# AWS EKS Platform — a production-shaped Kubernetes app on AWS

Running a containerized microservice on **Amazon EKS** the way a real team would:
provisioned entirely in **Terraform**, exposed through an **ALB Ingress**,
**auto-scaled** on load, deployed by a **keyless GitHub Actions pipeline**, and
proven resilient with a **pod-failure drill**.

This is the *"can you run Kubernetes on AWS?"* project — the day-to-day platform
skill most Cloud/DevOps roles ask for, on top of the serverless, container,
IaC, CI/CD, observability, and security work in my other repos.

**Status:** 🚧 Built in public, stage by stage (see the roadmap). Honest from
commit one — checkboxes are ticked only when the thing is actually running.

> **Cost & operating model.** An EKS control plane bills ~$0.10/hr **the whole
> time it exists**, unlike a fully free-tier serverless stack — so this project
> follows a deliberate **build → prove → destroy** loop: stand it up, capture real
> evidence (cluster up, ALB serving, HPA scaling, a pod self-healing), then
> `terraform destroy`. A full build-and-demo burst is ~$0.50–1. The Terraform
> makes it reproducible on demand for interviews. Cost breakdown in
> [`docs/cost.md`](docs/cost.md).

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

- [ ] **Stage 0 — Foundation.** Repo + this plan committed first. Reuse the
  existing GitHub OIDC provider; create a repo-scoped deploy role and an ECR
  repository (scan-on-push).
- [ ] **Stage 1 — The app.** A small containerized HTTP microservice (its own
  image + Dockerfile) with `/health` and an endpoint that reports which pod
  served the request (so load-balancing and self-healing are visible). Helm
  chart / manifests.
- [ ] **Stage 2 — EKS in Terraform.** VPC, an EKS cluster + managed node group,
  cluster IRSA/OIDC, least-privilege node role. `plan`-clean, not yet applied.
- [ ] **Stage 3 — Platform layer.** AWS Load Balancer Controller (via IRSA) →
  ALB Ingress; Metrics Server; a Horizontal Pod Autoscaler on the app.
- [ ] **Stage 4 — CI/CD.** GitHub Actions builds the image → ECR → deploys to
  the cluster over OIDC (no static keys). Rolling update on push.
- [ ] **Stage 5 — Operate & prove.** CloudWatch Container Insights; a
  **pod-failure drill** (delete a pod, watch the ReplicaSet self-heal) and an
  **HPA load test** (drive CPU, watch it scale out) — with measured evidence and
  a runbook. Then `terraform destroy`.

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
