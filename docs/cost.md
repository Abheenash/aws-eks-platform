# Cost model

EKS is **not** a free-tier-friendly, scale-to-zero service the way the serverless
projects are — the control plane bills by the hour for as long as the cluster
exists. So this project is run as a deliberate **build → prove → destroy** loop.

## What bills while the stack is up (us-east-1, on-demand)

| Component | Rate | ~Hourly |
|---|---|---|
| EKS control plane | $0.10 / hr | $0.10 |
| 2× `t3.small` nodes | ~$0.0208 / hr each | $0.042 |
| Application Load Balancer | ~$0.0225 / hr + LCUs | ~$0.03 |
| 1× NAT gateway | ~$0.045 / hr + data | ~$0.05 |
| EBS (node volumes), data | negligible for a demo | ~$0.01 |
| **Total** | | **~$0.23 / hr** |

## What a realistic session costs

A full **stand-up → verify → run the drills → tear down** burst is about
**2–3 hours** end to end (EKS control-plane creation alone is ~10–15 min), so:

> **≈ $0.50–$0.75 per demo run.** Left running 24×7 it would be ~$165/mo — which
> is exactly why it isn't.

## Discipline

- `terraform destroy` immediately after capturing evidence.
- `single_nat_gateway = true` (one NAT, not one per AZ).
- Small `t3.small` nodes, `desired_size = 2`.
- Everything is Terraform, so the environment is recreated on demand for an
  interview in ~15 minutes and destroyed again after.

## Verifying nothing is left billing

```
aws eks list-clusters --region us-east-1
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-nat-gateways --region us-east-1 --filter Name=state,Values=available
```

All three should be empty after `terraform destroy`.
