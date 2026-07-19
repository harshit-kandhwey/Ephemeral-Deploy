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

# Beat sets SKIP_INIT_DB=true. It shares this image and therefore this
# entrypoint with the worker, and both services start at the same time, so
# without this both containers race to CREATE ROLE / create_all / seed against
# the same database. The failures are swallowed as non-fatal below, which made
# the race easy to miss — it surfaced only as duplicate-key noise in the logs.
# The worker remains the single owner of initialisation.
if [[ "${SKIP_INIT_DB,,}" == "true" ]]; then
  echo "Skipping init_db (SKIP_INIT_DB=true — another service owns initialisation)"
# Only run init_db if master credentials are available
# (they won't be in local docker-compose where we use postgres superuser directly)
elif [[ -n "$DB_MASTER_USER" && -n "$DB_MASTER_PASSWORD" ]]; then
  echo "Running database init..."
  python -m src.init_db && echo "DB init complete" || echo "DB init failed (non-fatal)"
else
  echo "Skipping init_db (DB_MASTER_USER not set — local dev mode)"
fi

echo "Starting Celery worker..."
exec "$@"