from unittest.mock import MagicMock, patch

import pytest

from src import otel


@pytest.fixture(autouse=True)
def reset_otel_state():
    """otel._enabled is module-level global state — reset it around every
    test in this file only (not conftest.py, so no other suite is
    affected). Direct attribute reset, not importlib.reload: reload
    re-executes module-level code and can invalidate already-bound
    patch() targets for no benefit here, since _enabled is the only
    module-level state that matters."""
    otel._enabled = False
    yield
    otel._enabled = False


# All four lazily-imported OTel classes are imported INSIDE the functions
# (not at module load), so patching them at their own source module path
# works correctly — each call re-resolves the current binding.


def test_setup_tracing_is_noop_when_endpoint_unset(monkeypatch):
    monkeypatch.delenv("OTEL_EXPORTER_OTLP_ENDPOINT", raising=False)
    with patch("opentelemetry.trace.set_tracer_provider") as mock_set:
        otel.setup_tracing()
    mock_set.assert_not_called()
    assert otel._enabled is False


def test_setup_tracing_is_idempotent_when_already_enabled(monkeypatch):
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")
    otel._enabled = True
    with patch("opentelemetry.trace.set_tracer_provider") as mock_set:
        otel.setup_tracing()
    mock_set.assert_not_called()


def test_setup_tracing_configures_provider_when_endpoint_set(monkeypatch):
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")
    with (
        patch("opentelemetry.exporter.otlp.proto.http.trace_exporter.OTLPSpanExporter") as mock_exporter,
        patch("opentelemetry.sdk.trace.export.BatchSpanProcessor"),
        patch("opentelemetry.trace.set_tracer_provider") as mock_set,
    ):
        otel.setup_tracing()

    mock_exporter.assert_called_once_with(endpoint="http://collector:4318/v1/traces")
    mock_set.assert_called_once()
    assert otel._enabled is True


def test_setup_tracing_uses_default_service_name(monkeypatch):
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")
    monkeypatch.delenv("OTEL_SERVICE_NAME", raising=False)
    with (
        patch("opentelemetry.exporter.otlp.proto.http.trace_exporter.OTLPSpanExporter"),
        patch("opentelemetry.sdk.trace.export.BatchSpanProcessor"),
        patch("opentelemetry.trace.set_tracer_provider"),
        patch("opentelemetry.sdk.resources.Resource") as mock_resource,
    ):
        otel.setup_tracing()

    mock_resource.assert_called_once_with(attributes={"service.name": "nexusdeploy"})


def test_setup_tracing_respects_otel_service_name_env(monkeypatch):
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")
    monkeypatch.setenv("OTEL_SERVICE_NAME", "nexusdeploy-staging-api")
    with (
        patch("opentelemetry.exporter.otlp.proto.http.trace_exporter.OTLPSpanExporter"),
        patch("opentelemetry.sdk.trace.export.BatchSpanProcessor"),
        patch("opentelemetry.trace.set_tracer_provider"),
        patch("opentelemetry.sdk.resources.Resource") as mock_resource,
    ):
        otel.setup_tracing()

    mock_resource.assert_called_once_with(attributes={"service.name": "nexusdeploy-staging-api"})


def test_instrument_is_noop_when_not_enabled():
    otel._enabled = False
    with (
        patch("opentelemetry.instrumentation.flask.FlaskInstrumentor") as mock_flask,
        patch("opentelemetry.instrumentation.sqlalchemy.SQLAlchemyInstrumentor") as mock_sqla,
        patch("opentelemetry.instrumentation.redis.RedisInstrumentor") as mock_redis,
        patch("opentelemetry.instrumentation.celery.CeleryInstrumentor") as mock_celery,
    ):
        otel.instrument(MagicMock())

    mock_flask.assert_not_called()
    mock_sqla.assert_not_called()
    mock_redis.assert_not_called()
    mock_celery.assert_not_called()


def test_instrument_calls_all_four_instrumentors_when_enabled():
    """Asserted individually — a single 'instrument() ran without error'
    check would miss one instrumentor silently being dropped."""
    otel._enabled = True
    fake_app = MagicMock()
    with (
        patch("opentelemetry.instrumentation.flask.FlaskInstrumentor") as mock_flask,
        patch("opentelemetry.instrumentation.sqlalchemy.SQLAlchemyInstrumentor") as mock_sqla,
        patch("opentelemetry.instrumentation.redis.RedisInstrumentor") as mock_redis,
        patch("opentelemetry.instrumentation.celery.CeleryInstrumentor") as mock_celery,
    ):
        otel.instrument(fake_app)

    mock_flask.return_value.instrument_app.assert_called_once_with(fake_app)
    mock_sqla.return_value.instrument.assert_called_once()
    mock_redis.return_value.instrument.assert_called_once()
    mock_celery.return_value.instrument.assert_called_once()
