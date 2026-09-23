# Porting this workload to OpenShift

`openshift/` is the same application as `k8s/`, running under OpenShift instead of
EKS. Diffing the two directories is the point — every difference is forced by
something real, and none of it is cosmetic.

I wrote this because OpenShift shows up constantly in enterprise job requisitions
and almost never in portfolios, and because the failure mode is specific enough
that "I've used Kubernetes" does not cover it.

## The one that breaks everything: SCCs and the arbitrary UID

EKS runs the pod as whatever `runAsUser` says. OpenShift does not.

Under the default `restricted-v2` Security Context Constraint, every namespace is
allocated a UID range (something like `1000730000/10000`), and pods are injected
with a UID from it. A manifest that hard-codes `runAsUser: 10001` is **rejected
outright** unless 10001 falls inside that namespace's range — which it will not.

So `runAsUser` comes out. `runAsNonRoot: true` stays, because that is an assertion
about what must be true, not an instruction about which user to be.

This has knock-on effects the manifest cannot fix on its own:

| Consequence | Why | Fix |
|---|---|---|
| The UID has no `/etc/passwd` entry | It was invented at admission time | Set `HOME` explicitly; make the image tolerate `getpwuid()` failing |
| Files owned by uid 10001 are unreadable | The container is a different user now | Own app files by **group 0** and make them group-readable |
| Anything writing to its own directory fails | Random UID owns nothing | Write only to a mounted `emptyDir` (already true here — `readOnlyRootFilesystem: true` forced it) |

The Dockerfile change that makes an image OpenShift-portable:

```dockerfile
# Instead of: RUN useradd --uid 10001 ... && USER appuser
RUN chgrp -R 0 /app && chmod -R g=u /app
USER 10001
```

`USER 10001` stays as a *default* for plain Docker and EKS; OpenShift overrides it
and the group-0 ownership is what makes that override harmless. This is the single
most useful thing to know about running someone else's image on OpenShift.

## Ingress becomes a Route

The EKS side's Ingress is mostly ALB-controller annotations — scheme, target-type,
healthcheck path, deregistration delay, the ACM certificate ARN. On OpenShift none
of those exist. A `Route` points at a Service, and TLS is terminated by the
cluster router using its own wildcard certificate, so there is no certificate to
provision or reference at all.

Less to configure, and less control: the ALB gives a WAF, access logs and
per-target health checks that the OpenShift router simply does not have opinions
about.

## Service type changes

EKS: `NodePort`, because the ALB target group registers node ports.
OpenShift: `ClusterIP`, because the router reaches the Service directly. Exposing
node ports here would be strictly worse for no benefit.

## What did not change

The interesting part. Both probes, the same endpoints, the same
`terminationGracePeriodSeconds: 45` and 15-second `preStop` — the fix for the
drill finding in [`RESULTS-2026-07-12.md`](RESULTS-2026-07-12.md) where 3 of 400
requests failed during deregistration. The reason that fix ports cleanly is that
it was never about the ALB; it was about the pod not disappearing while something
still had it in a routing table. Every ingress layer has that problem.

Resource requests and limits, the topology spread constraint, the dropped
capabilities, the read-only root filesystem and the `emptyDir` for `/tmp` are all
identical. `restricted-v2` would have demanded most of them anyway — which is a
fair argument that OpenShift's defaults are stricter than EKS's, and that a
workload built properly for EKS is most of the way there already.

## Not applied

These manifests are `kubectl apply --dry-run`-shaped, not proven on a live
cluster. I do not have an OpenShift cluster to run them on, and CRC on a laptop
would not tell you anything honest about SCC behaviour in a real multi-tenant
namespace. Treat this as a reading of the differences, not a measured result —
the EKS side is where the measured evidence lives.
