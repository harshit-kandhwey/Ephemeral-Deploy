FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    postgresql-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1000 appuser

WORKDIR /app

# Install Python dependencies first (layer cache — only invalidated when requirements.txt changes)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source
COPY . /app/

# Fix permissions
RUN chown -R appuser:appuser /app

USER appuser

# Health check
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