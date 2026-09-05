"""OpenTelemetry tracing — opt-in via OTEL_EXPORTER_OTLP_ENDPOINT. Empty or
unset disables all of it (no exporter, no auto-instrumentation): local dev
and tests never set it, so tracing is a pure no-op there. See
docs/design-decisions.md#self-hosted-tracing-otel-collector--jaeger-not-x-ray.
"""

import logging
import os

logger = logging.getLogger(__name__)

_enabled = False


def setup_tracing():
    """Idempotent. Safe to call from create_app() regardless of which
    service (api/worker/beat) is booting — all three share it."""
    global _enabled
    if _enabled:
        return
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")
    if not endpoint:
        return

    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    service_name = os.environ.get("OTEL_SERVICE_NAME", "nexusdeploy")
    provider = TracerProvider(resource=Resource(attributes={"service.name": service_name}))
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{endpoint}/v1/traces")))
    trace.set_tracer_provider(provider)
    _enabled = True
    logger.info("OTel tracing enabled: service=%s endpoint=%s", service_name, endpoint)


def instrument(app):
    """Auto-instruments Flask, SQLAlchemy, Redis and Celery. Flask/Celery
    instrumentation is harmless-but-idle on a service that never uses it
    (e.g. Flask's on worker/beat, which run no WSGI server) — kept
    unconditional across all three services rather than special-cased, and
    Celery producer-side spans matter even on api: they're what lets a
    trace continue from an enqueuing request into the worker that later
    processes it.
    """
    if not _enabled:
        return

    from opentelemetry.instrumentation.celery import CeleryInstrumentor
    from opentelemetry.instrumentation.flask import FlaskInstrumentor
    from opentelemetry.instrumentation.redis import RedisInstrumentor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

    FlaskInstrumentor().instrument_app(app)
    SQLAlchemyInstrumentor().instrument()
    RedisInstrumentor().instrument()
    CeleryInstrumentor().instrument()
