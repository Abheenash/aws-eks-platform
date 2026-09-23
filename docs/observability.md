# Two observability stacks, same questions

`cloud-observability-sre` answers "is this service healthy?" with **CloudWatch**,
on a serverless stack. This repo answers it with **Prometheus and Grafana**, on
Kubernetes. Same golden signals, same SLO, completely different primitives —
which is the point of having both.

| | CloudWatch (cloud-observability-sre) | Prometheus (here) |
|---|---|---|
| Collection | push — the service emits | **pull** — Prometheus scrapes `/metrics` |
| Discovery | you name the resource | **ServiceMonitor**, label-selected |
| Query | metric math expressions | **PromQL** |
| Histograms | percentiles computed at write time | **buckets**, percentile computed at read time |
| Alerts | `aws_cloudwatch_metric_alarm` | **PrometheusRule**, evaluated in-cluster |
| Dashboards | JSON in Terraform | JSON in `dashboards/`, provisioned by ConfigMap |
| Cost | per metric, per alarm, per dashboard | **the pods' own CPU and memory** |
| Retention | 15 months, managed | 6h here, because this cluster is temporary |

## The three things that actually differ

### 1. Pull discovery is why the ServiceMonitor is load-bearing

In CloudWatch you name a function and the metrics are there. Prometheus has to
*find* the target. A `/metrics` endpoint nobody scrapes is silent, and the most
common cause is the one this chart configures around:
`serviceMonitorSelectorNilUsesHelmValues=false`. Left at its default, Prometheus
only discovers ServiceMonitors carrying its own release label — so the app's
monitor in the `demo` namespace is ignored, with no error anywhere.

### 2. Histogram buckets are a decision you make in advance

CloudWatch computes p95 from the raw values it stored. Prometheus stores
**counts per bucket**, and `histogram_quantile` interpolates within whichever
bucket the answer falls in. If the SLO is 500 ms and the nearest bucket edges are
0.25 and 1.0, the p95 reading is a guess between them.

So the buckets in `app/main.py` are chosen around the SLO
(`…0.25, 0.5, 1.0…`), not left at the library defaults. That is a real design
decision that has no CloudWatch equivalent.

### 3. Cardinality is an availability risk, not a cost line

CloudWatch charges per custom metric — sloppy dimensions cost money. In
Prometheus, a label with unbounded values consumes memory in the server until it
falls over. A scanner hitting `/wp-admin`, `/.env` and a thousand other URLs
would mint a thousand time series that never get collected.

That is why the middleware labels by **matched route template** and collapses
everything else to `unmatched`, and why `tests/test_metrics.py` fires 25 distinct
404s and asserts exactly one series comes out. It is the test I would most want
to see in someone else's instrumentation.

## Reading it

Nothing is exposed publicly. Both UIs are reached by port-forward, because an
internet-facing Grafana is a credentialled window onto every metric in the
cluster:

```bash
kubectl -n monitoring port-forward svc/kps-grafana 3000:80          # Grafana
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090     # Prometheus
```

## Status

**Validated, not applied.** `terraform validate` is clean, the manifests parse,
the dashboard JSON is valid, and the instrumentation is unit-tested — including
the cardinality guard. The stack has never run on a live cluster, so there are no
screenshots and no measured scrape numbers, and this page does not pretend
otherwise. The measured drill evidence in this repo is still v2's, from
2026-07-12.
