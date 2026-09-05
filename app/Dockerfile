# ── Stage 1: builder ─────────────────────────────────────────────────────────
# Compilers live here and nowhere else. Dependencies are installed into a
# plain directory (not a venv) that the runtime stage copies wholesale, so
# gcc and the build headers never reach the shipped image.
#
# --target=/opt/deps, not a venv: a venv's console scripts (bin/gunicorn) and
# its bin/python* symlinks are shebang'd/pointed at THIS stage's absolute
# python path (/usr/local/bin/python), which does not exist in the distroless
# runtime stage — copying a venv across bases breaks every entry point in it.
# A --target install has no such indirection: it is just importable packages,
# consumed via PYTHONPATH by whichever python3 actually runs them. See
# docs/design-decisions.md#distroless-runtime-images.
FROM python:3.11-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir --target=/opt/deps -r requirements.txt


# ── Stage 2: runtime ─────────────────────────────────────────────────────────
# Distroless, not python:3.11-slim: no shell, no package manager, no curl —
# nothing an attacker who reaches this container can execute besides the
# Python interpreter itself. See
# docs/design-decisions.md#distroless-runtime-images for the consequences
# (exec-form-only healthcheck, ECS Exec drops into python3 instead of a
# shell) and why psycopg2-binary makes this safe (it bundles its own libpq,
# nothing here depends on a system package).
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
# No ENTRYPOINT override: the distroless base's own
# ENTRYPOINT ["/usr/bin/python3.11"] is kept, and CMD below supplies its
# arguments — "-m gunicorn ..." runs gunicorn as a module instead of via a
# console-script shebang (see the builder stage comment for why).
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
