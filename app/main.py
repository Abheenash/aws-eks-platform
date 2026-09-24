"""aws-eks-platform demo microservice.

Deliberately tiny, but built so the Kubernetes behaviours are *observable*:
  GET /healthz -> liveness: the process can answer (never depends on anything else)
  GET /ready   -> readiness: the pod is accepting traffic (false while draining)
  GET /        -> reports which POD served the request (see the ALB rotate pods,
                  and watch a deleted pod get replaced by the ReplicaSet)
  GET /burn    -> spikes CPU so the Horizontal Pod Autoscaler scales out

Drill finding (docs/RESULTS-2026-07-12.md): a pod restarted under load because the
liveness probe timed out — the old /burn was a pure-Python busy loop, which holds the
GIL, so the probe thread never ran. /burn now does its work in a child process; the
API process stays responsive no matter how hard it's burning.
"""
import contextlib
import json
import logging
import multiprocessing
import os
import signal
import socket
import sys
import threading
import time

from fastapi import FastAPI, Request, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

app = FastAPI(title="aws-eks-platform demo", docs_url=None, redoc_url=None, openapi_url=None)

POD = os.environ.get("POD_NAME", socket.gethostname())
VERSION = os.environ.get("APP_VERSION", "v1")
MAX_BURN_MS = int(os.environ.get("MAX_BURN_MS", "10000"))

_log = logging.getLogger("web")
_log.setLevel(logging.INFO)
_h = logging.StreamHandler(sys.stdout)
_h.setFormatter(logging.Formatter("%(message)s"))
_log.handlers = [_h]
_log.propagate = False

# Draining: on SIGTERM the pod keeps serving but reports not-ready, so the ALB
# target group deregisters it BEFORE connections stop being accepted. Pairs with
# the preStop sleep and terminationGracePeriodSeconds in the Deployment.
_draining = threading.Event()


def _on_term(signum, frame):
    _draining.set()
    _log.info(json.dumps({"pod": POD, "event": "draining", "signal": signum}))


# Not the main thread when tests import the module from a worker, and signal
# handlers can only be installed from the main thread.
with contextlib.suppress(ValueError):
    signal.signal(signal.SIGTERM, _on_term)


def _burn_worker(seconds, out):
    end = time.time() + seconds
    n = 0
    while time.time() < end:
        n += 1
    out.value = n


# --- Prometheus metrics ------------------------------------------------------
#
# Labelled by the ROUTE TEMPLATE, never the raw path. Labelling with request.url.path
# would mint a new time series per distinct URL, which is how a Prometheus falls over
# — the classic high-cardinality mistake.
REQUESTS = Counter(
    "http_requests_total", "HTTP requests.", ["method", "route", "status"]
)
LATENCY = Histogram(
    "http_request_duration_seconds", "HTTP request latency.", ["method", "route"],
    # Buckets chosen around this service's actual behaviour and the SLO it is held
    # to, not the library defaults: the p95 target is 500 ms.
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)
IN_FLIGHT = Gauge("http_requests_in_flight", "Requests currently being served.")
# No `pod` label here on purpose. Prometheus's Kubernetes service discovery already
# attaches pod, namespace, node and container to every sample it scrapes, and when
# an exported label collides with a target label Prometheus keeps the target's and
# renames ours to `exported_pod` — so a `pod` label here produces two
# nearly-identical labels and queries that silently match neither. Confirmed in a
# live cluster: the series came back as
# app_build_info{pod="...", exported_pod="...", version="v1"}.
BUILD = Gauge("app_build_info", "Build metadata; always 1.", ["version"])
BUILD.labels(version=os.environ.get("APP_VERSION", "dev")).set(1)


def _route_of(request: Request) -> str:
    """The matched route template ('/burn'), or 'unmatched' for a 404.

    Returning request.url.path here would defeat the point: a scanner hitting
    /wp-admin, /.env and a thousand other paths would create a thousand series.
    """
    route = request.scope.get("route")
    return getattr(route, "path", None) or "unmatched"


@app.middleware("http")
async def access_log(request: Request, call_next):
    t0 = time.time()
    IN_FLIGHT.inc()
    try:
        response: Response = await call_next(request)
    finally:
        IN_FLIGHT.dec()
    elapsed = time.time() - t0
    route = _route_of(request)
    # /metrics is excluded so the scrape does not measure itself.
    if route != "/metrics":
        REQUESTS.labels(request.method, route, str(response.status_code)).inc()
        LATENCY.labels(request.method, route).observe(elapsed)
    if request.url.path not in ("/healthz", "/ready"):  # probes would drown the log
        _log.info(json.dumps({"pod": POD, "method": request.method, "path": request.url.path,
                              "status": response.status_code, "ms": round(elapsed * 1000, 1)}))
    response.headers["X-Pod"] = POD
    return response


@app.get("/metrics")
def metrics():
    """Scrape endpoint. The ServiceMonitor in k8s/servicemonitor.yaml points here."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/healthz")
def healthz():
    return {"status": "ok", "pod": POD}


@app.get("/health")  # kept for the old ALB health-check path
def health():
    return healthz()


@app.get("/ready")
def ready(response: Response):
    if _draining.is_set():
        response.status_code = 503
        return {"status": "draining", "pod": POD}
    return {"status": "ready", "pod": POD}


@app.get("/")
def root():
    return {
        "message": "Hello from Amazon EKS 👋",
        "pod": POD,
        "version": VERSION,
        "hint": "refresh to watch the ALB rotate pods; hit /burn to trigger the HPA",
    }


@app.get("/burn")
def burn(ms: int = 2000):
    """Burn CPU in a child process (so this process — and its liveness probe — stays
    responsive) for up to MAX_BURN_MS."""
    ms = max(0, min(ms, MAX_BURN_MS))
    out = multiprocessing.Value("q", 0)
    p = multiprocessing.Process(target=_burn_worker, args=(ms / 1000.0, out), daemon=True)
    p.start()
    p.join(timeout=ms / 1000.0 + 5)
    if p.is_alive():
        p.kill()
    return {"pod": POD, "burned_ms": ms, "iterations": int(out.value)}
