# Case study — AWS EKS Platform

## Context

My portfolio shows **build → ship → operate** across serverless and containers,
but the recurring gap for a Cloud/DevOps target was **Kubernetes** — it's a hard
filter in a large share of job postings. This project fills it with a real,
Terraform-provisioned EKS platform: an app exposed through an ALB Ingress,
auto-scaled by an HPA, deployed by a keyless CI/CD pipeline, and **proven under
failure with measured drills** — not a screenshot of `kubectl get pods`.

## What I built

- **EKS cluster in Terraform** using the official `terraform-aws-modules` (vpc +
  eks) — a 2-AZ VPC, a managed node group, core addons, IRSA/OIDC, and a modern
  **EKS access entry** (not the legacy `aws-auth` ConfigMap) granting the CI role
  cluster access.
- **Platform layer:** the AWS Load Balancer Controller (running with **IRSA** —
  scoped IAM via its service account, not node-wide creds) turns `Ingress`
  objects into real ALBs; Metrics Server feeds the HPA.
- **A small FastAPI app** deliberately built so Kubernetes behaviour is
  *observable*: `/` reports which pod served you (see load-balancing + self-heal),
  `/burn` drives CPU (trigger the HPA). Hardened pod: non-root, read-only root FS,
  dropped capabilities, resource requests/limits, topology spread, zero-downtime
  rollout.
- **Keyless CI/CD** (GitHub Actions + OIDC): build `linux/amd64` → ECR → roll out
  to EKS. It skips the deploy cleanly when the cluster is torn down.

## The operating model — build → prove → destroy

Unlike my serverless projects (near-free), EKS bills ~$0.10/hr for the control
plane the whole time it exists. So this runs as a disciplined loop: stand it up,
capture evidence, tear it down. A full burst is **~$0.30–0.50**; the Terraform
recreates it in ~15 minutes on demand for an interview. Cost math in
[`docs/cost.md`](docs/cost.md).

## Proven live (2026-07-12)

`terraform apply` → 66 resources, 0 errors; 2 nodes Ready, controllers healthy;
app deployed with an even 10/10 load-balance across pods. Then two drills:

- **Pod self-heal:** deleted a pod under live traffic → replaced and back to 2/2 in
  **7 seconds**, with **3 failed requests out of 400** (0.75%).
- **HPA scale-out:** drove CPU with 14 clients → scaled **2 → 6** (first scale-out
  ~45s, max ~60s), held steady, then scaled back on the default window.

Then `terraform destroy`, verified clean. Details:
[`docs/RESULTS-2026-07-12.md`](docs/RESULTS-2026-07-12.md).

## The honest findings (what a real run teaches)

- **It wasn't truly zero-downtime.** Those 3 failed requests happened because the
  ALB was still routing to the terminating pod before it deregistered from the
  target group. A naive demo would claim "zero downtime"; the real fix is a
  `preStop` drain + a longer `deregistration_delay` so the ALB drains the pod
  *before* it dies.
- **A liveness probe can trip under CPU saturation.** One pod restarted during the
  HPA drill because the `/burn` busy-loop starved the `/health` handler. Lesson:
  don't let CPU-bound work share the request path with the liveness endpoint.
- **Teardown ordering matters.** The ALB is created by the controller, not
  Terraform — so the `Ingress` must be deleted first (letting the controller remove
  the ALB) or `terraform destroy` hangs on the VPC's orphaned ENIs.

## What I'd do next

- `preStop` hook + tuned `deregistration_delay` to close the self-heal gap.
- Cluster Autoscaler / Karpenter so node capacity scales with the HPA under
  heavier load.
- CloudWatch Container Insights + alarms (reuses my observability project's
  golden-signals approach) and a canary.
- GitOps (Argo CD) so cluster state is reconciled from git rather than pushed.
