# ── Stage 1: builder ─────────────────────────────────────────────────────────
# Compilers live here and nowhere else — gcc/build headers never reach the
# shipped image. --target=/opt/deps, not a venv: a venv breaks across base
# images. See docs/design-decisions.md#distroless-runtime-images.
FROM python:3.11-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir --target=/opt/deps -r requirements.txt


# ── Stage 2: runtime ─────────────────────────────────────────────────────────
# Distroless, not python:3.11-slim: no shell, no package manager, no curl.
# See docs/design-decisions.md#distroless-runtime-images.
FROM gcr.io/distroless/python3-debian12:nonroot

COPY --from=builder /opt/deps /opt/deps
ENV PYTHONPATH=/opt/deps \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# .dockerignore keeps tests, caches and local env files out of the image.
# nonroot base already runs as uid 65532 — no separate useradd/USER step.
COPY --chown=65532:65532 . /app/

# Exec-form only: no shell to run `curl ... || exit 1` in.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["python3", "/app/healthcheck.py"]

EXPOSE 5000

# ── Entry point explanation ───────────────────────────────────────────────────
# No ENTRYPOINT override — the distroless base's own python3.11 is kept, and
# CMD below is its arguments. See docs/design-decisions.md#distroless-runtime-images.
#
# --chdir src        → Gunicorn changes into /app/src before starting.
#                      This makes 'wsgi' resolve to /app/src/wsgi.py correctly,
#                      which is what works both locally AND in ECS (no volume mount).
#
# --workers 2        → Formula: (2 x vCPU) + 1. On 0.25 vCPU Fargate task,
#                      4 workers would OOM (512MB shared across 4 processes).
#                      2 workers is the safe value for this task size.
#
# --threads 2        → Each worker handles 2 concurrent requests via threading.
#                      Total concurrency = 2 workers x 2 threads = 4 req at once.
#
# --worker-class gthread → Required when using --threads > 1. Default 'sync'
#                           worker ignores the --threads flag entirely.
# ─────────────────────────────────────────────────────────────────────────────
CMD ["-m", "gunicorn", \
    "--chdir", "src", \
    "--bind", "0.0.0.0:5000", \
    "--workers", "2", \
    "--threads", "2", \
    "--worker-class", "gthread", \
    "--timeout", "120", \
    "--access-logfile", "-", \
    "--error-logfile", "-", \
    "--log-level", "info", \
    "wsgi:app"]
