import os
from datetime import timedelta
from urllib.parse import urlparse, urlunparse


def _get_ratelimit_redis_url():
    ratelimit_redis_url = os.environ.get("RATELIMIT_REDIS_URL")
    if ratelimit_redis_url:
        return ratelimit_redis_url

    redis_url = os.environ.get("REDIS_URL")
    if redis_url:
        parsed = urlparse(redis_url)
        path = (parsed.path or "/").rstrip("/") + "/1"
        return urlunparse(
            (
                parsed.scheme,
                parsed.netloc,
                path,
                parsed.params,
                parsed.query,
                parsed.fragment,
            )
        )

    return "redis://localhost:6379/1"


class Config:
    """Base configuration"""

    SECRET_KEY = os.environ.get("SECRET_KEY")

    SQLALCHEMY_DATABASE_URI = os.environ.get("DATABASE_URL") or "sqlite:///dev.db"
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    SQLALCHEMY_ECHO = False

    REDIS_URL = os.environ.get("REDIS_URL") or "redis://localhost:6379/0"

    CELERY_BROKER_URL = os.environ.get("CELERY_BROKER_URL") or "redis://localhost:6379/0"
    CELERY_RESULT_BACKEND = os.environ.get("CELERY_RESULT_BACKEND") or "redis://localhost:6379/0"

    JWT_SECRET_KEY = os.environ.get("JWT_SECRET_KEY") or os.environ.get("SECRET_KEY")
    JWT_ACCESS_TOKEN_EXPIRES = timedelta(hours=1)
    JWT_REFRESH_TOKEN_EXPIRES = timedelta(days=30)

    AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
    S3_BUCKET = os.environ.get("S3_BUCKET", "nexusdeploy-attachments")

    RATELIMIT_STORAGE_URL = _get_ratelimit_redis_url()

    ENV = os.environ.get("ENV", "development")
    VERSION = os.environ.get("VERSION", "unknown")
    DEBUG = False
    TESTING = False


class DevelopmentConfig(Config):
    """
    Development configuration.
    Safe fallback values so the app starts without any environment setup.
    These values are intentionally obvious — they must never reach production.
    """

    DEBUG = True
    SQLALCHEMY_ECHO = True
    SECRET_KEY = os.environ.get("SECRET_KEY") or "dev-secret-key-DO-NOT-USE-IN-PROD-32b"
    JWT_SECRET_KEY = (
        os.environ.get("JWT_SECRET_KEY") or os.environ.get("SECRET_KEY") or "dev-secret-key-DO-NOT-USE-IN-PROD-32b"
    )


class ProductionConfig(Config):
    """
    Production configuration.
    No fallback values for required secrets — all resolve to None if absent.
    Startup validation in app.py's create_app() checks for missing values and
    raises a RuntimeError listing every missing variable before the app binds
    to any port, ensuring fast and visible failure rather than silent misconfig.

    All values are injected by ECS from AWS Secrets Manager at container launch.
    The flow is:
        SSM Parameter Store
            → Terraform reads and assembles into Secrets Manager secret
                → ECS injects as environment variables at task launch
                    → App reads here via os.environ.get()
    """

    DEBUG = False
    SQLALCHEMY_ECHO = False

    # All three values below deliberately use .get() with no fallback so they
    # resolve to None when the env var is absent. They are NOT fail-fast here
    # by design — the validation block in app.py's create_app() is the single
    # authoritative place that checks for missing values and raises a
    # RuntimeError with a clear message listing every missing variable at once.
    # Using os.environ['KEY'] here would raise a bare KeyError at import time
    # with no context, before the logger is even configured.
    SECRET_KEY = os.environ.get("SECRET_KEY")  # validated in app.py
    JWT_SECRET_KEY = os.environ.get("JWT_SECRET_KEY") or os.environ.get(  # validated in app.py
        "SECRET_KEY"
    )  # acceptable fallback: same key, different claim

    # No SQLite fallback. None here causes SQLAlchemy to raise at startup
    # rather than silently connecting to a local file — validated in app.py.
    SQLALCHEMY_DATABASE_URI = os.environ.get("DATABASE_URL")


class TestingConfig(Config):
    """
    Testing configuration.
    Uses in-memory SQLite so tests run without any external services.
    Redis is pointed at DB 15 to avoid polluting other databases if
    a local Redis happens to be running.
    """

    TESTING = True
    SQLALCHEMY_DATABASE_URI = "sqlite:///:memory:"
    REDIS_URL = "redis://localhost:6379/15"
    # Disable rate limiting in tests
    RATELIMIT_ENABLED = False


config = {
    "development": DevelopmentConfig,
    "production": ProductionConfig,
    "testing": TestingConfig,
    "default": DevelopmentConfig,
}
