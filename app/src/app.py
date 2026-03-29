import logging
import time

from flask import Flask, jsonify
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from sqlalchemy import text

from .config import config
from .extensions import cors, db, init_celery, init_redis, jwt, limiter, migrate, swagger

# ── Prometheus metrics ────────────────────────
# Defined at module level so they survive across requests.
# Exposed at /metrics for Prometheus scraping.
REQUEST_COUNT = Counter("app_requests_total", "Total HTTP requests", ["method", "endpoint", "status"])
REQUEST_LATENCY = Histogram("app_request_latency_seconds", "HTTP request latency in seconds", ["endpoint"])


def create_app(config_name="default"):
    """Application factory"""
    app = Flask(__name__)
    app.config.from_object(config[config_name])

    # ── Production startup validation ─────────
    # Fail loudly at startup if required secrets are missing.
    # Better to crash immediately with a clear message than to start
    # and fail on the first real request, or worse — use wrong config silently.
    if config_name == "production":
        missing = []

        if not app.config.get("SECRET_KEY"):
            missing.append("SECRET_KEY")

        if not app.config.get("JWT_SECRET_KEY"):
            missing.append("JWT_SECRET_KEY (or SECRET_KEY as fallback)")

        if not app.config.get("SQLALCHEMY_DATABASE_URI"):
            missing.append(
                "SQLALCHEMY_DATABASE_URI (set via DATABASE_URL env var) — "
                "without this the app has no database. "
                "Check that ECS Secrets Manager injection is configured correctly."
            )

        if missing:
            for var in missing:
                app.logger.critical("STARTUP FAILED: missing required env var: %s", var)
            raise RuntimeError(
                "Production startup failed. Missing environment variables:\n" + "\n".join(f"  - {v}" for v in missing)
            )

    # ── Extensions ────────────────────────────
    db.init_app(app)
    migrate.init_app(app, db)
    jwt.init_app(app)
    limiter.init_app(app)
    cors.init_app(app)
    init_redis(app)
    init_celery(app)

    # ── Swagger / API docs ────────────────────
    app.config["SWAGGER"] = {
        "title": "NexusDeploy Project Management API",
        "version": app.config["VERSION"],
        "description": "Production-grade project management API",
        "termsOfService": "",
        "hide_top_bar": False,
        "securityDefinitions": {
            "Bearer": {
                "type": "apiKey",
                "name": "Authorization",
                "in": "header",
                "description": 'JWT Authorization header. Example: "Bearer {token}"',
            }
        },
        "security": [{"Bearer": []}],
    }
    swagger.init_app(app)

    # ── Logging ───────────────────────────────
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    # ── Blueprints ────────────────────────────
    from .api.v1 import api_v1

    app.register_blueprint(api_v1, url_prefix="/api/v1")

    # ── Request metrics middleware ────────────
    @app.before_request
    def before_request():
        from flask import request

        request.start_time = time.time()

    @app.after_request
    def after_request(response):
        from flask import request

        if hasattr(request, "start_time"):
            latency = time.time() - request.start_time
            REQUEST_LATENCY.labels(endpoint=request.endpoint or "unknown").observe(latency)
            REQUEST_COUNT.labels(
                method=request.method,
                endpoint=request.endpoint or "unknown",
                status=response.status_code,
            ).inc()
        return response

    # ── Health check ──────────────────────────
    # Used by:
    #   - ECS container health check (restarts unhealthy tasks)
    #   - Dockerfile HEALTHCHECK instruction
    #   - Blue-green deployment health polling in deploy.yml
    @app.route("/health")
    def health():
        from .extensions import redis_client

        # Database check
        try:
            db.session.execute(text("SELECT 1"))
            db_status = "healthy"
        except Exception as e:
            app.logger.error(f"Database health check failed: {e}")
            return (
                jsonify(
                    {
                        "status": "unhealthy",
                        "database": "unhealthy",
                        "redis": "unknown",
                        "version": app.config["VERSION"],
                        "environment": app.config["ENV"],
                    }
                ),
                503,
            )

        # Redis check
        try:
            redis_client.ping()
            redis_status = "healthy"
        except Exception as e:
            app.logger.error(f"Redis health check failed: {e}")
            redis_status = "unhealthy"

        overall = "healthy" if redis_status == "healthy" else "unhealthy"
        return jsonify(
            {
                "status": overall,
                "database": db_status,
                "redis": redis_status,
                "version": app.config["VERSION"],
                "environment": app.config["ENV"],
            }
        ), (200 if overall == "healthy" else 503)

    # ── Readiness probe ───────────────────────
    # Separate from /health — used by load balancers / orchestrators
    # to know when the container is ready to receive traffic.
    @app.route("/ready")
    def ready():
        return jsonify({"ready": True}), 200

    # ── Prometheus metrics endpoint ───────────
    # Scraped by Prometheus running on the monitoring EC2.
    # Returns all counters and histograms registered at module level above.
    @app.route("/metrics")
    def metrics():
        return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

    # ── Root ──────────────────────────────────
    @app.route("/")
    def home():
        return (
            jsonify(
                {
                    "message": "NexusDeploy Project Management API",
                    "version": app.config["VERSION"],
                    "environment": app.config["ENV"],
                    "documentation": "/apidocs",
                }
            ),
            200,
        )

    # ── Error handlers ────────────────────────
    @app.errorhandler(404)
    def not_found(error):
        return jsonify({"error": "Not found"}), 404

    @app.errorhandler(500)
    def internal_error(error):
        app.logger.error(f"Internal error: {error}")
        db.session.rollback()
        return jsonify({"error": "Internal server error"}), 500

    return app
