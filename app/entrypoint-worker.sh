#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# Worker entrypoint — runs init_db before starting Celery
# This ensures schema + NexusAppUser exist on every deploy
# without requiring a separate pipeline step.
# Idempotent: safe to run on every container startup.
# ─────────────────────────────────────────────────────────────────
set -e

echo "=== Worker Entrypoint ==="
echo "ENV: ${ENV:-development}"

# Only run init_db if master credentials are available
# (they won't be in local docker-compose where we use postgres superuser directly)
if [[ -n "$DB_MASTER_USER" && -n "$DB_MASTER_PASSWORD" ]]; then
  echo "Running database init..."
  python -m src.init_db && echo "DB init complete" || echo "DB init failed (non-fatal)"
else
  echo "Skipping init_db (DB_MASTER_USER not set — local dev mode)"
fi

echo "Starting Celery worker..."
exec "$@"