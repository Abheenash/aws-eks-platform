# Architecture

```mermaid
flowchart TB
  dev[Push to main] --> gha[GitHub Actions\nOIDC, no static keys]
  gha -->|build linux/amd64| ecr[(Amazon ECR)]
  gha -->|kubectl set image / rollout| eks

  subgraph AWS[AWS · us-east-1]
    subgraph VPC[VPC 10.0.0.0/16]
      alb[Application Load Balancer\ninternet-facing]
      subgraph EKS[Amazon EKS · managed control plane]
        ing[Ingress · alb class]
        svc[Service · ClusterIP]
        subgraph NG[Managed node group · t3.small x2]
          p1[web pod]
          p2[web pod]
          p3[web pod ...]
        end
        albc[AWS Load Balancer Controller\nIRSA]
        ms[Metrics Server]
        hpa[HorizontalPodAutoscaler\nCPU 50% · 2→6]
      end
    end
  end

  user[Recipient / recruiter] -->|HTTP| alb
  alb --> ing --> svc --> p1 & p2 & p3
  ecr -.image.-> p1
  albc -.provisions.-> alb
  ms --> hpa
  hpa -.scales.-> NG
```

## Components

- **Amazon EKS (managed control plane)** — Kubernetes API/etcd run by AWS;
  Terraform provisions the cluster, addons (CoreDNS, kube-proxy, VPC CNI), and a
  managed EC2 node group.
- **VPC** — two AZs, public + private subnets; nodes run in private subnets with
  a single NAT gateway for egress. Subnets are tagged for ALB auto-discovery.
- **AWS Load Balancer Controller** — watches `Ingress` objects and provisions a
  real ALB with pod-IP target groups. Runs with **IRSA** (scoped IAM via its
  service account), not node-wide credentials.
- **Ingress → Service → Pods** — the ALB routes to a ClusterIP Service, which
  load-balances across the `web` Deployment's pods.
- **Metrics Server + HPA** — CPU metrics feed the HorizontalPodAutoscaler, which
  scales the Deployment 2→6 under load.
- **GitHub Actions (OIDC)** — builds the amd64 image, pushes to ECR, and rolls it
  out to the cluster with no static AWS keys. Cluster access is granted to the
  CI role through a modern **EKS access entry**.

## Security posture

- Keyless CI (OIDC), IRSA for in-cluster AWS access, least-privilege node role.
- Non-root container, read-only root filesystem, dropped Linux capabilities,
  `RuntimeDefault` seccomp, resource requests/limits.
- Private node subnets; the API server is public-endpoint but RBAC-gated via
  access entries.
