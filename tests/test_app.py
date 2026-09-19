import os
import sys
import threading
import time

from fastapi.testclient import TestClient

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
import main  # noqa: E402

client = TestClient(main.app)


def test_probes_and_root():
    assert client.get("/healthz").json()["status"] == "ok"
    assert client.get("/health").json()["status"] == "ok"
    assert client.get("/ready").json()["status"] == "ready"
    r = client.get("/")
    assert r.status_code == 200 and r.json()["pod"] == main.POD and r.headers["X-Pod"] == main.POD


def test_burn_is_bounded_and_counts():
    r = client.get("/burn?ms=200")
    assert r.status_code == 200 and r.json()["burned_ms"] == 200 and r.json()["iterations"] > 0
    assert client.get("/burn?ms=99999999").json()["burned_ms"] == main.MAX_BURN_MS
    assert client.get("/burn?ms=-5").json()["burned_ms"] == 0


def test_liveness_answers_while_burning():
    """The drill finding: the probe must not starve while /burn runs."""
    done = threading.Event()
    threading.Thread(target=lambda: (client.get("/burn?ms=1500"), done.set()), daemon=True).start()
    time.sleep(0.2)  # let the burn start
    t0 = time.time()
    r = client.get("/healthz")
    elapsed = time.time() - t0
    assert r.status_code == 200
    assert elapsed < 0.5, f"liveness took {elapsed:.2f}s during a burn"
    done.wait(5)


def test_sigterm_flips_readiness_but_keeps_serving():
    main._draining.clear()
    main._on_term(15, None)
    try:
        r = client.get("/ready")
        assert r.status_code == 503 and r.json()["status"] == "draining"
        assert client.get("/").status_code == 200        # still serving in-flight traffic
        assert client.get("/healthz").status_code == 200  # liveness unaffected: no restart loop
    finally:
        main._draining.clear()


def test_docs_disabled():
    assert client.get("/docs").status_code == 404
