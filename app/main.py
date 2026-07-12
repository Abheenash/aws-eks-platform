"""aws-eks-platform demo microservice.

Deliberately tiny, but built so the Kubernetes behaviours are *observable*:
  GET /health  -> liveness/readiness probe target
  GET /        -> reports which POD served the request (see the ALB rotate pods,
                  and watch a deleted pod get replaced by the ReplicaSet)
  GET /burn    -> busy-loops to spike CPU, so the Horizontal Pod Autoscaler
                  scales the Deployment out under load
"""
import os
import socket
import time

from fastapi import FastAPI

app = FastAPI(title="aws-eks-platform demo")

POD = os.environ.get("POD_NAME", socket.gethostname())
VERSION = os.environ.get("APP_VERSION", "v1")


@app.get("/health")
def health():
    return {"status": "ok", "pod": POD}


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
    """Burn CPU for up to 10s to drive the Horizontal Pod Autoscaler."""
    ms = max(0, min(ms, 10000))
    end = time.time() + ms / 1000.0
    iterations = 0
    while time.time() < end:
        iterations += 1
    return {"pod": POD, "burned_ms": ms, "iterations": iterations}
