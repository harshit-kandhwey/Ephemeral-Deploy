import os
from datetime import timedelta
from urllib.parse import urlparse, urlunparse


def _env_flag(name, default=False):
    """Read a boolean from the environment. Empty/unset falls back to default."""
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _get_cors_origins():
    """
    Comma-separated allowlist of browser origins, e.g.
        CORS_ORIGINS=https://console.example.com,https://admin.example.com

    Default is an empty list — no cross-origin browser access. The monitoring
    console is served same-origin through the nginx reverse proxy, so it needs
    no CORS grant. A bare CORS() would send Access-Control-Allow-Origin: * on an
    authenticated API, which is what we are avoiding here.
    """
    raw = os.environ.get("CORS_ORIGINS", "")
    return [origin.strip() for origin in raw.split(",") if origin.strip()]


def redact_url(url):
    """
    Mask the password in a URL so it is safe to log.

    Redis/DB URLs carry credentials in the netloc; CloudWatch retains whatever
    we print, so never log one raw.
    """
    if not url:
        return repr(url)
    try:
        parsed = urlparse(url)
    except ValueError:
        return "<unparseable>"
    if parsed.password:
        netloc = parsed.netloc.replace(f":{parsed.password}@", ":***@", 1)
        parsed = parsed._replace(netloc=netloc)
    return urlunparse(parsed)


def _get_ratelimit_redis_url():
    ratelimit_redis_url = os.environ.get("RATELIMIT_REDIS_URL")
    if ratelimit_redis_url:
        return ratelimit_redis_url

    redis_url = os.environ.get("REDIS_URL")
    if redis_url:
        parsed = urlparse(redis_url)
        # A Redis URL's path IS the database index ("/0"), so isolating rate
        # limits on DB 1 means REPLACING that segment, not appending to it.
        # Appending turned "redis://host:6379/0" into "redis://host:6379/0/1",
        # a path of "/0/1" that is not a valid database selector.
        return urlunparse(
            (
                parsed.scheme,
                parsed.netloc,
                "/1",
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

    # flask-limiter >= 3 reads RATELIMIT_STORAGE_URI. The old RATELIMIT_STORAGE_URL
    # spelling was dropped in 4.x, where it is silently ignored — the limiter then
    # falls back to in-memory storage, making every limit per-gunicorn-worker and
    # resetting it on restart. Redis-backed storage is what makes limits global.
    RATELIMIT_STORAGE_URI = _get_ratelimit_redis_url()

    # A Redis blip must not 500 every request. With swallow_errors the limiter
    # logs the storage failure and allows the request through (fail-open on
    # rate limiting, not on auth) instead of raising.
    RATELIMIT_SWALLOW_ERRORS = True

    CORS_ORIGINS = _get_cors_origins()

    # Swagger UI at /apidocs. On by default for dev/testing; ProductionConfig
    # turns it off unless ENABLE_SWAGGER is explicitly set, so a staging demo
    # can still expose it without a code change.
    ENABLE_SWAGGER = _env_flag("ENABLE_SWAGGER", default=True)

    # Minimum password length. The 72-byte ceiling is enforced in the API layer:
    # bcrypt silently truncates beyond 72 bytes, so a longer passphrase would
    # give a false sense of strength.
    MIN_PASSWORD_LENGTH = 8

    ENV = os.environ.get("ENV", "development")
    VERSION = os.environ.get("VERSION", "unknown")

    # Enabled per-config below; deployed dev must not run with DEBUG on.
    DEBUG = False
    TESTING = False


class DevelopmentConfig(Config):
    """
    Development configuration.
    Safe fallback values so the app starts without any environment setup.
    These values are intentionally obvious — they must never reach production.

    DEBUG and SQLALCHEMY_ECHO default on for local work but are env-gated,
    because the *deployed* dev environment also loads this config (ECS sets
    ENV=development there). SQLALCHEMY_ECHO logs every statement with its bind
    parameters — bcrypt hashes and emails — and on ECS those go to CloudWatch,
    so dev's task definition turns both off.
    """

    DEBUG = _env_flag("FLASK_DEBUG", default=True)
    SQLALCHEMY_ECHO = _env_flag("SQLALCHEMY_ECHO", default=True)
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

    # Swagger UI is off in production unless explicitly enabled. It advertises
    # every route and schema to anyone who can reach the API.
    ENABLE_SWAGGER = _env_flag("ENABLE_SWAGGER", default=False)

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

    # Fixed test-only keys. Without these the suite cannot run unless the caller
    # happens to export SECRET_KEY/JWT_SECRET_KEY — CI does, a developer running
    # `pytest` locally does not, and flask-jwt-extended then raises at init.
    # Values are deliberately obvious and carry no meaning outside tests.
    SECRET_KEY = os.environ.get("SECRET_KEY") or "testing-secret-key-not-used-anywhere-else"
    JWT_SECRET_KEY = os.environ.get("JWT_SECRET_KEY") or "testing-jwt-secret-key-not-used-anywhere-else"

    # Rate limiting off in tests: limits are stateful across requests and would
    # make test order significant. The limiter's config is exercised separately.
    RATELIMIT_ENABLED = False


config = {
    "development": DevelopmentConfig,
    "production": ProductionConfig,
    "testing": TestingConfig,
    "default": DevelopmentConfig,
}
