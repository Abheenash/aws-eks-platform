"""Prometheus instrumentation.

The cardinality test is the one that matters. Labelling by raw request path is the
classic way to take a Prometheus down: a scanner probing /wp-admin, /.env and a
thousand other URLs mints a thousand time series that never get garbage collected.
Labelling by matched ROUTE bounds the series count at the size of the route table.
"""
import importlib
import pathlib
import re
import sys

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "app"))


@pytest.fixture
def client():
    main = importlib.import_module("main")
    return TestClient(main.app, raise_server_exceptions=False)


def _routes(body):
    return re.findall(r'route="([^"]+)"', body)


def test_metrics_endpoint_serves_prometheus_text(client):
    r = client.get("/metrics")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    assert "http_requests_total" in r.text
    assert "http_request_duration_seconds" in r.text


def test_unmatched_paths_collapse_to_one_series(client):
    for i in range(25):
        client.get(f"/definitely-not-a-route-{i}")
    body = client.get("/metrics").text
    routes = set(_routes(body))
    assert "unmatched" in routes
    assert not [r for r in routes if r.startswith("/definitely-not-a-route")], (
        "raw request paths must never become label values — that is unbounded cardinality"
    )


def test_metrics_endpoint_does_not_measure_itself(client):
    client.get("/metrics")
    body = client.get("/metrics").text
    assert "/metrics" not in set(_routes(body))


def test_known_routes_are_labelled_by_template(client):
    client.get("/healthz")
    body = client.get("/metrics").text
    assert 'route="/healthz"' in body


def test_build_info_is_exported(client):
    body = client.get("/metrics").text
    assert "app_build_info" in body
