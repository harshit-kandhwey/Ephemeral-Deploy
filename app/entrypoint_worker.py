#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────
# Worker entrypoint — runs init_db before starting Celery. Idempotent,
# safe on every startup. Python, not bash: no shell in the distroless
# image. See docs/design-decisions.md#distroless-runtime-images.
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
        # Beat shares this image/entrypoint and starts at the same time as
        # the worker — without this both would race to init the same DB.
        # The worker stays the sole initialiser.
        print("Skipping init_db (SKIP_INIT_DB=true — another service owns initialisation)")
    elif db_master_user and db_master_password:
        # Master creds are absent in local docker-compose (uses the
        # postgres superuser directly) — that's the only other branch.
        print("Running database init...")
        # Hard failure, not swallowed: every init step is idempotent, so a
        # failure here means a real fault, and ECS's restart-and-retry
        # (plus the health gate) is the right way to handle it.
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
    # Run as a module (no console-script binary exists here) via execv, not
    # subprocess.run, so celery replaces this process (PID 1) and gets
    # SIGTERM directly. See docs/design-decisions.md#distroless-runtime-images.
    os.execv(sys.executable, [sys.executable, "-m"] + argv)


if __name__ == "__main__":
    main()
