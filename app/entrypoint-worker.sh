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
  # Hard failure, not the old `|| echo "(non-fatal)"`. That form overrode
  # set -e and let the worker start on top of a database with no schema —
  # tolerable only while beat was redundantly initialising too. Beat now skips
  # init, so the worker is the SOLE initialiser and a swallowed error would
  # leave a nominally-deployed stack with no usable schema and nothing to
  # retry it.
  #
  # Safe to exit here because every step is idempotent: create_app_user checks
  # pg_roles first, create_schema uses db.create_all(), and seed_sample_data
  # only runs against an empty user table. A re-run on an initialised database
  # succeeds, so this can only crash-loop on a real fault (unreachable DB, bad
  # master credentials, a failing migration) — which is exactly when it should.
  # ECS supplies the retry: the task restarts and the entrypoint runs again,
  # and a persistent failure trips the deployment circuit breaker and is caught
  # by the worker/beat health gate before anything is promoted.
  if ! python -m src.init_db; then
    echo "DB init failed — refusing to start the worker without a usable schema" >&2
    exit 1
  fi
  echo "DB init complete"
else
  echo "Skipping init_db (DB_MASTER_USER not set — local dev mode)"
fi

echo "Starting Celery worker..."
exec "$@"