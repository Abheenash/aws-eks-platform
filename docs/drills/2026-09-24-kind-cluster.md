# Drill — the manifests and alerts, run against a real cluster

**Date:** 2026-09-24 · **Cluster:** kind v0.33.0, Kubernetes v1.37.0, 1 control-plane
+ 2 workers, on a laptop · **Cost:** zero

This repo's Terraform is validated, not applied — there is no EKS cluster behind it
and no bill. But `terraform validate` says nothing about whether the *Kubernetes*
side works: whether Prometheus finds the app, whether the alert expressions match
the metric names the app actually emits, whether the rollout is really
zero-downtime, whether the HPA does anything at all.

So the Kubernetes layer was run for real on kind. Everything below is measured
output, not a description of intent. Two of the checks failed, and both were bugs
in this repo.

The only edits to the manifests were the image reference (`eks-demo:local`,
`imagePullPolicy: Never`, since there is no registry) and a Helm release named
`kps` instead of `kube-prometheus-stack`. Nothing else was changed to make the
drill pass.

---

## What was verified

| # | Claim | Result |
|---|---|---|
| 1 | Prometheus discovers the app's ServiceMonitor across namespaces | ✅ both pods `health=up` |
| 2 | Every alert expression resolves against real metrics | ⚠️ 2 bugs found, fixed |
| 3 | A rolling deploy drops no requests | ✅ 40/40 × HTTP 200 |
| 4 | Losing every replica at once | ❌ ~2 s outage (7 requests) — expected, measured |
| 5 | A node drain respects the PDB and reschedules | ✅ 100/100 × HTTP 200 |
| 6 | The HPA scales on CPU | ✅ 2 → 6 in 75 s, once metrics-server existed |
| 7 | The NetworkPolicies isolate the namespace | ⚠️ the first version allowed everything — fixed, then verified |

---

## 1. Cross-namespace ServiceMonitor discovery

`docs/observability.md` claims the chart's default `serviceMonitorSelector` would
silently ignore the app's monitor. The drill makes that concrete: the Helm release
was called **`kps`**, while `k8s/servicemonitor.yaml` carries
`release: kube-prometheus-stack` — a label that matches nothing. With
`serviceMonitorSelectorNilUsesHelmValues: false` the rendered Prometheus CR is:

```
serviceMonitorSelector={}   serviceMonitorNamespaceSelector={}
ruleSelector={}             ruleNamespaceSelector={}
```

Empty selectors match everything, so discovery worked *despite* the mismatched
label — which is the proof that the override, not the label, is load-bearing.
Targets after the reload:

```
"job":"serviceMonitor/demo/web/0"  "pod":"web-…-dz7f2"  "scrapeUrl":"http://10.244.1.2:8080/metrics"  "health":"up"  "lastError":""
"job":"serviceMonitor/demo/web/0"  "pod":"web-…-mr4l5"  "scrapeUrl":"http://10.244.2.2:8080/metrics"  "health":"up"  "lastError":""
```

The app's own series arrived with the route template as a label, not the raw path —
including the 404s, which collapse to a single `unmatched` series rather than one
series per scanned URL:

```
{route="/healthz", status="200"} 64      {route="/",         status="200"} 7
{route="/ready",   status="200"} 125     {route="unmatched", status="404"} 3
```

**Bug found.** `app_build_info` came back as
`app_build_info{pod="web-…", exported_pod="web-…", version="v1"}`. The app was
exporting its own `pod` label, Kubernetes service discovery attaches one too, and
on a collision Prometheus keeps the target's and renames the exporter's to
`exported_pod`. Two near-identical labels, and a query written against either one
silently misses half the time. The label was removed from `app/main.py`; the pod
identity comes from the scrape, where it is authoritative.

## 2. The alert expressions — two silent failures

All five rules loaded with `health=ok`, and every vector they depend on resolves:
`kube_deployment_status_replicas_available{namespace="demo",deployment="web"}` = 2,
84 `http_request_duration_seconds_bucket` series, p95 = 4.8 ms. A rule that is
`health=ok` is only proof that it *parses*, though. Evaluating the expressions by
hand found two that parse fine and can never fire.

**`sum()` over no series returns an empty vector, not zero.**

```
sum(rate(http_requests_total{route!="unmatched",status=~"5.."}[5m]))              => EMPTY VECTOR
sum(rate(http_requests_total{route!="unmatched",status=~"5.."}[5m])) or vector(0) => 0
```

With no 5xx anywhere, the error-ratio recording rule produced *nothing* rather than
0 — `empty / anything` is empty. The burn-rate alerts would not have fired wrongly
(zero errors should not page), but the SLO panel shows a gap instead of a flat zero
line, and "healthy" becomes indistinguishable from "the exporter is gone".

The second one is worse, because it defeats the alert's entire purpose:

```
    sum(rate(http_requests_total{job="absent"}[5m])) == 0    => EMPTY VECTOR
(sum(rate(http_requests_total{job="absent"}[5m])) or vector(0)) == 0  => 0
```

`WebNoTraffic` exists to catch the case the ratio alerts structurally cannot see —
the app going completely silent. But if the app disappears, its series go stale and
drop out after five minutes, `sum(rate(...))` becomes empty, and `empty == 0` is
empty. The alert stops evaluating in exactly the outage it was written for. The
comment above it in `cluster/prometheus-rules.yaml` called it "the compensating
control"; it was a no-op.

Both are fixed with `or vector(0)`. Re-applied and confirmed in the same cluster —
`job:web_request_error_ratio:rate5m` went from `EMPTY VECTOR` to `0`, all seven
rules `health=ok`, no evaluation errors.

## 3. Rolling deploy — 40/40 requests served

A load generator inside the cluster hit the Service every 200 ms while
`kubectl rollout restart` replaced both pods:

```
rollout completed in 6s
40 requests: 200=40
```

Zero failures, and the reason is three things agreeing: `maxUnavailable: 0` means a
new pod is Ready before an old one goes away, the readiness probe gates Service
endpoints, and `preStop: sleep 15` keeps the terminating pod answering while
kube-proxy catches up with the endpoint removal. Drop any one and this number stops
being 40.

## 4. Losing every replica at once — ~2 s, 7 failed requests

The honest counter-test. `delete pod -l app=web --grace-period=0 --force` skips the
graceful path entirely — the shape of both nodes losing their kubelet at once:

```
00:23:20  000 NONE
00:23:21  000 NONE   (×4)
00:23:22  000 NONE
27 requests: 000=7  200=20
2/2 ready again after 3s
```

Seven connection failures over roughly two seconds. Nothing in the manifests can
prevent this — no replica was left to serve. It is here because a drill that only
runs the scenarios you expect to pass is not a drill.

**Caveat, stated plainly:** 3 s recovery is a laptop number. The image was already
on the node (`imagePullPolicy: Never`). On EKS pulling from ECR, recovery is
dominated by image pull and would be tens of seconds.

## 5. Node drain — PDB respected, 100/100 served

The path a managed-node-group upgrade or a Spot reclaim actually takes, via the
eviction API rather than a delete:

```
evicting pod demo/web-6874d68bdd-g8c55
pod/web-6874d68bdd-g8c55 evicted
node/eks-local-worker drained        (17s)

before:  web-…-g8c55  eks-local-worker      after:  web-…-9vnzx  eks-local-worker2
         web-…-pmj66  eks-local-worker2             web-…-pmj66  eks-local-worker2
100 requests during the drain: 200=100
```

`minAvailable: 1` held — the evicted pod was replaced before the drain returned.
The replacement landed on the surviving worker, which is only possible because the
spread constraint is `whenUnsatisfiable: ScheduleAnyway`. With `DoNotSchedule` the
pod would have been unschedulable until the drained node came back, and a routine
node upgrade would have run at half capacity. That is the trade-off the constraint
is making, and this drill is what shows it is the right way round.

## 6. The HPA — inert for 16 minutes, then correct

The HPA read `cpu: <unknown>/50%` from the moment it was applied, and its events
said why:

```
Warning  FailedGetResourceMetric  (x41 over 16m)  failed to get cpu utilization:
  unable to fetch metrics from resource metrics API: the server could not find the
  requested resource (get pods.metrics.k8s.io)
```

An HPA with no metrics source is a YAML file that does nothing, and it reports
`Healthy` in `kubectl get deploy`. Installing metrics-server — same chart and
version as `terraform/platform.tf`, `3.13.0` with `--kubelet-insecure-tls` — fixed
it in 20 s. Then, under sustained `/burn` load:

```
cpu: 204%/50%
SuccessfulRescale  New size: 4; reason: cpu resource utilization above target
SuccessfulRescale  New size: 6; reason: cpu resource utilization above target
```

2 → 4 → 6 in 75 seconds, capped at `maxReplicas`, 3 pods on each worker — the
spread constraint held through the scale-up. Per-pod CPU settled at 133–298 m
against a 300 m limit, i.e. the limit was doing its job as well.

Scale-down is the asymmetric half, and the asymmetry is the point:

```
load stopped at 00:29:06
  t= 51s  replicas=6  util=15%
  t=111s  replicas=6  util=5%
  t=233s  replicas=6  util=5%
  t=293s  replicas=6  util=5%
scaled back to 2 after 324s
```

Utilization collapsed to 5% within two minutes; replicas did not move for another
three and a half. That is the default `scaleDown.stabilizationWindowSeconds: 300`
plus one HPA sync interval — up in 75 s, down in 324 s. `k8s/hpa.yaml` sets no
`behavior` block and so inherits it, which is the right default (flapping a
deployment costs more than five minutes of spare capacity) but is worth having
chosen rather than discovered during an incident.

---

## 7. The NetworkPolicies — written wrong, then proved right

checkov's `CKV2_K8S_6` flagged that no pod in `demo` had a NetworkPolicy, which was
true and worth fixing: with none, any compromised pod anywhere in the cluster can
reach this one, and this one can reach the whole VPC.

Testing them needs a CNI that enforces NetworkPolicy, and kind's default (kindnet)
does not — it accepts the objects and enforces nothing. So this ran on a second kind
cluster with `disableDefaultCNI: true` and **Calico v3.31.0**. That distinction is
the same one that matters on EKS, where the VPC CNI needs
`enableNetworkPolicy = "true"` before any of this does anything;
`terraform/eks.tf` now sets it.

**The first version of the policy allowed everything.** The rule meant to admit ALB
traffic was written as:

```yaml
  ingress:
    - ports:
        - protocol: TCP
          port: 8080
```

which reads like "allow port 8080" and means "allow port 8080 **from anywhere**" — a
rule with no `from` matches every source, so it re-opened everything `default-deny`
had just closed. Measured, not reasoned about:

```
                              before policies   with the broken rule   with the fix
other/      -> web /healthz        200                 200             000 (timeout)
monitoring/ -> web /metrics        200                 200             200
```

The middle column is the whole point of running it. Both the broken and the fixed
policy are valid YAML, pass `kubeconform -strict`, and satisfy checkov — the only
thing that told them apart was a pod in an unrelated namespace getting a 200.

The fix also changed scope. The obvious `ipBlock` for an ALB is the VPC CIDR
(`10.0.0.0/16`), and on EKS that is close to no restriction at all: the VPC CNI gives
every **pod** a VPC address too, so "from the VPC" includes every pod in the cluster.
The rule names the two public /24s where the ALB's ENIs actually live, leaving the
private subnets — nodes and pods — outside the allowlist.

Egress was checked the same way, from inside the running pod:

```
DNS resolve kubernetes.default: 10.96.0.1     <- allow-dns-egress works
egress to 1.1.1.1:              URLError      <- default-deny holds
```

## What this does not prove

The Kubernetes layer ran; the AWS layer did not. Nothing here exercises the ALB
Controller, Karpenter provisioning real nodes, EKS Pod Identity against real IAM,
IRSA, the ECR pull path, or Argo CD reconciling from a real repo. Those remain
`terraform validate` and `terraform test` with mocked providers. kind gives you the
API server and the kubelet honestly, and nothing else.

## Reproducing

```sh
kind create cluster --config local/kind.yaml
docker build -t eks-demo:local app/ && kind load docker-image eks-demo:local --name eks-local
kubectl apply -f k8s/
# no registry in a kind cluster — point the Deployment at the side-loaded image
kubectl -n demo set image deploy/web app=eks-demo:local
kubectl -n demo patch deploy web --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]'
helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
  --version 3.13.0 --set 'args[0]=--kubelet-insecure-tls'
kubectl apply -f cluster/prometheus-rules.yaml
```

The NetworkPolicy section needs a second cluster, because kindnet does not enforce
NetworkPolicy:

```sh
kind create cluster --config local/kind-netpol.yaml   # disableDefaultCNI: true
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
kubectl apply -f k8s/networkpolicy.yaml
```

Teardown is `kind delete cluster --name eks-local` (and `--name np-test`). Both
clusters for this drill were deleted afterwards; they cost nothing either way.
