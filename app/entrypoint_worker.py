#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────
# Worker entrypoint — runs init_db before starting Celery.
# This ensures schema + NexusAppUser exist on every deploy
# without requiring a separate pipeline step.
# Idempotent: safe to run on every container startup.
#
# Python, not bash: the distroless runtime image has no shell to run a
# .sh script in. See docs/design-decisions.md#distroless-runtime-images.
# ─────────────────────────────────────────────────────────────────
import os
import subprocess
import sys


def main() -> None:
    print("=== Worker Entrypoint ===")
    print(f"ENV: {os.environ.get('ENV', 'development')}")

    skip_init_db = os.environ.get("SKIP_INIT_DB", "").lower() == "true"
    db_master_user = os.environ.get("DB_MASTER_USER", "")
    db_master_password = os.environ.get("DB_MASTER_PASSWORD", "")

    if skip_init_db:
        # Beat sets SKIP_INIT_DB=true. It shares this image and therefore this
        # entrypoint with the worker, and both services start at the same
        # time, so without this both containers race to CREATE ROLE /
        # create_all / seed against the same database. The worker remains the
        # single owner of initialisation.
        print("Skipping init_db (SKIP_INIT_DB=true — another service owns initialisation)")
    elif db_master_user and db_master_password:
        # Only run init_db if master credentials are available (they won't
        # be in local docker-compose, where we use the postgres superuser
        # directly).
        print("Running database init...")
        # Hard failure, not a swallowed one: that would let the worker start
        # on top of a database with no schema.
        #
        # Safe to fail loudly because every step is idempotent:
        # create_app_user checks pg_roles first, create_schema uses
        # db.create_all(), and seed_sample_data only runs against an empty
        # user table. A re-run on an initialised database succeeds, so this
        # can only crash-loop on a real fault (unreachable DB, bad master
        # credentials, a failing migration) — which is exactly when it
        # should. ECS supplies the retry: the task restarts and the
        # entrypoint runs again, and a persistent failure trips the
        # deployment circuit breaker and is caught by the worker/beat
        # health gate before anything is promoted.
        result = subprocess.run([sys.executable, "-m", "src.init_db"])
        if result.returncode != 0:
            print("DB init failed — refusing to start the worker without a usable schema", file=sys.stderr)
            sys.exit(1)
        print("DB init complete")
    else:
        print("Skipping init_db (DB_MASTER_USER not set — local dev mode)")

    print("Starting Celery worker...")
    argv = sys.argv[1:]
    if not argv:
        print("No command given to exec", file=sys.stderr)
        sys.exit(1)
    # argv is ["celery", "-A", ..., "worker"|"beat", ...] — run it as a
    # module (`python3 -m celery ...`), not as a console-script binary:
    # there is no such binary here (--target installs don't create one), and
    # there is no shell/`env` to resolve one via PATH or a shebang either way.
    # execv, not subprocess.run: replaces this process in place (PID 1 stays
    # PID 1), matching bash's `exec "$@"` — celery must receive SIGTERM
    # directly from ECS/Docker, not from a parent python process relaying it.
    os.execv(sys.executable, [sys.executable, "-m"] + argv)


if __name__ == "__main__":
    main()
