"""
Rate-limiting configuration tests.

These guard two regressions that are invisible at runtime until they bite:

  1. The storage URI key. flask-limiter reads RATELIMIT_STORAGE_URI; the older
     RATELIMIT_STORAGE_URL spelling is ignored in 4.x, and the limiter silently
     falls back to per-process memory. Limits then reset on restart and apply
     per gunicorn worker rather than globally.

  2. Exemption of the operational endpoints. The default limits (200/day,
     50/hour) apply to every route that does not set its own. ECS polls /health
     every 30s (120/hour) and Prometheus scrapes /metrics every 15s (240/hour),
     so without an exemption both get 429s — and a 429 to the container health
     check reads as an unhealthy task, which ECS kills and replaces.
"""

import pytest

from src import create_app
from src.config import TestingConfig
from src.extensions import db


@pytest.fixture
def limited_client(monkeypatch):
    """
    A client with rate limiting actually switched on.

    The normal test config disables it (limits are stateful and would make test
    order significant), so the exemption cannot be observed there. Storage is
    forced to memory:// to keep the test hermetic — no Redis required.
    """
    monkeypatch.setattr(TestingConfig, "RATELIMIT_ENABLED", True)
    monkeypatch.setattr(TestingConfig, "RATELIMIT_STORAGE_URI", "memory://")

    app = create_app("testing")
    with app.app_context():
        db.create_all()
        yield app.test_client()
        db.session.remove()
        db.drop_all()


def test_storage_uri_key_is_set():
    """
    The config must expose RATELIMIT_STORAGE_URI (not the legacy _URL spelling),
    and it must point at Redis — otherwise limits are per-process and not global.
    """
    app = create_app("testing")
    assert app.config.get("RATELIMIT_STORAGE_URI"), "RATELIMIT_STORAGE_URI missing — limiter falls back to memory"
    assert "RATELIMIT_STORAGE_URL" not in TestingConfig.__dict__


def test_storage_uri_defaults_to_redis_db_1():
    """Rate-limit counters live on their own Redis DB, away from app data."""
    app = create_app("development")
    assert app.config["RATELIMIT_STORAGE_URI"].startswith("redis://")
    assert app.config["RATELIMIT_STORAGE_URI"].endswith("/1")


def test_swallow_errors_enabled():
    """A Redis outage must degrade rate limiting, not 500 every request."""
    app = create_app("testing")
    assert app.config["RATELIMIT_SWALLOW_ERRORS"] is True


@pytest.mark.parametrize("endpoint", ["/health", "/ready", "/metrics"])
def test_operational_endpoints_are_exempt(limited_client, endpoint):
    """
    Poll well past the 50/hour default limit. ECS and Prometheus both exceed it
    within the hour, so any 429 here means task churn in production.
    """
    for i in range(60):
        response = limited_client.get(endpoint)
        assert response.status_code != 429, f"{endpoint} was rate limited after {i} requests"


def test_default_limits_still_apply_to_api_routes(limited_client):
    """
    The exemption must be surgical: ordinary API routes keep their limits.
    A test that only proved /health was exempt would also pass if rate limiting
    had been turned off entirely.
    """
    statuses = {limited_client.get("/api/v1/teams").status_code for _ in range(60)}
    assert 429 in statuses, "default limits are not being applied to API routes"
