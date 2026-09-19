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


try:
    signal.signal(signal.SIGTERM, _on_term)
except ValueError:
    pass  # not the main thread (tests import the module from a worker)


def _burn_worker(seconds, out):
    end = time.time() + seconds
    n = 0
    while time.time() < end:
        n += 1
    out.value = n


@app.middleware("http")
async def access_log(request: Request, call_next):
    t0 = time.time()
    response: Response = await call_next(request)
    if request.url.path not in ("/healthz", "/ready"):  # probes would drown the log
        _log.info(json.dumps({"pod": POD, "method": request.method, "path": request.url.path,
                              "status": response.status_code, "ms": round((time.time() - t0) * 1000, 1)}))
    response.headers["X-Pod"] = POD
    return response


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
