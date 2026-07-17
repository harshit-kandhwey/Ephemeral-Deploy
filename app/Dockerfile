# ── Stage 1: builder ─────────────────────────────────────────────────────────
# Compilers live here and nowhere else. Dependencies are installed into a venv
# that the runtime stage copies wholesale, so gcc and the build headers never
# reach the shipped image.
FROM python:3.11-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# A venv is the cleanest unit to hand to the runtime stage: one directory that
# carries the interpreter's view of every installed package.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt


# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM python:3.11-slim

# curl is required: the HEALTHCHECK below and the ECS container health check
# both shell out to it. gcc, libpq-dev and postgresql-client are deliberately
# absent — nothing at runtime compiles anything, and no code path shells out to
# psql (entrypoint-worker.sh uses python only).
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 appuser

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# .dockerignore keeps tests, caches and local env files out of the image.
COPY --chown=appuser:appuser . /app/

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:5000/health || exit 1

EXPOSE 5000

# ── Entry point explanation ───────────────────────────────────────────────────
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
CMD ["gunicorn", \
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
