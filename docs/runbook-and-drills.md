# Runbook & resilience drills

Two drills prove the platform behaves under stress the way Kubernetes promises.
Results tables are filled in **only after a real run** — no fabricated numbers
(the same integrity rule as the aws-cloudops-lab project). `<fill after run>`
markers are honest placeholders.

Prereqs: cluster up, app deployed, `kubectl` pointed at the cluster, and the ALB
address from `kubectl -n demo get ingress web`.

---

## Drill 1 — pod failure & self-healing

**Hypothesis:** deleting a pod causes zero user-visible downtime; the ReplicaSet
replaces it automatically and the ALB stops routing to it via the readiness probe.

**Steps**
```bash
# watch replacement happen
kubectl -n demo get pods -w &

# delete one pod
kubectl -n demo delete pod "$(kubectl -n demo get pods -l app=web -o jsonpath='{.items[0].metadata.name}')"

# hammer the ALB throughout and confirm no failed requests
ALB=$(kubectl -n demo get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for i in $(seq 1 200); do curl -s -o /dev/null -w "%{http_code} " "http://$ALB/"; done; echo
```

**Expected:** a new pod reaches `Running`/`Ready` within seconds; the curl loop
stays all `200` (the deleted pod is drained via readiness before it dies).

**Results** (measured 2026-07-12 — see [`RESULTS-2026-07-12.md`](RESULTS-2026-07-12.md))

| Metric | Value |
|---|---|
| Time to new pod `Ready` (back to 2/2) | **7 s** |
| Failed requests during recovery | **3 / 400** (2×502, 1×000 ≈ 0.75%) |
| Pods observed serving (before → after) | even 10/10 split → replaced, back to 2/2 |

> Honest finding: not fully zero-downtime — a couple of 502s while the ALB was
> still routing to the terminating pod before deregistration completed. Fix: a
> `preStop` drain + longer `deregistration_delay`.

---

## Drill 2 — Horizontal Pod Autoscaler under load

**Hypothesis:** sustained CPU load pushes average utilization past the 50% HPA
target, and the Deployment scales out (2 → up to 6), then scales back in when
load stops.

**Steps**
```bash
kubectl -n demo get hpa web -w &        # watch replicas climb

# generate CPU load via the /burn endpoint from several parallel clients
ALB=$(kubectl -n demo get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
for i in $(seq 1 20); do (while true; do curl -s "http://$ALB/burn?ms=8000" >/dev/null; done &) ; done

# ...observe scale-out, then stop the load:
pkill -f "curl -s http://$ALB/burn"
```

**Expected:** replicas rise toward `maxReplicas: 6` within ~1–3 min, then return
to `minReplicas: 2` after the default 5-min stabilization window.

**Results** (measured 2026-07-12 — see [`RESULTS-2026-07-12.md`](RESULTS-2026-07-12.md))

| Metric | Value |
|---|---|
| Peak CPU utilization | ~300% of request (hit the 300m limit) |
| Replicas: min → peak | **2 → 6** (the cap) |
| Time to first scale-out (2→4) | **~45 s** |
| Time to reach max (→6) | **~60 s** |
| Scale back in | default 5-min stabilization window (not waited out — cost) |

> Honest finding: one pod restarted once under peak load — its liveness probe
> tripped when the CPU busy-loop starved `/health`. Lesson: don't let CPU-bound
> work share the request path with the liveness endpoint.

---

## Runbook — "the app is returning 5xx / is unreachable"

1. **Pods healthy?** `kubectl -n demo get pods` — look for `CrashLoopBackOff`,
   `ImagePullBackOff`, or `0/1 READY`.
2. **Recent rollout?** `kubectl -n demo rollout history deployment/web`; roll back
   with `kubectl -n demo rollout undo deployment/web` if a bad image shipped.
3. **Ingress / ALB?** `kubectl -n demo describe ingress web`; check the ALB target
   group health in the console — unhealthy targets usually mean the readiness
   probe (`/health`) is failing.
4. **Controller alive?** `kubectl -n kube-system logs deploy/aws-load-balancer-controller`
   — IRSA/permission errors show here if the ALB never provisions.
5. **Capacity?** `kubectl -n demo describe hpa web` and `kubectl top pods -n demo`
   — pending pods may mean the node group is at `max_size` (raise it or the HPA cap).
