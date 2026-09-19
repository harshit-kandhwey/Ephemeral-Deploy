#!/usr/bin/env python3
"""Post-promotion smoke test.

Run as a one-off ECS task (worker image, command override) inside the VPC
against the newly promoted slot's private task IP — the ALB is disabled, so
that address isn't reachable from the GitHub Actions runner directly. See
docs/design-decisions.md#post-promotion-smoke-test.

Goes beyond `/health` (DB/Redis connectivity only): exercises the real
login route end-to-end — password verification, JWT signing, blueprint and
rate-limiter wiring. Login is read-only (no side effect), so this is safe
to run on every promoted deploy, using the seeded admin account.

Deliberately not run via `aws ecs execute-command`: the API/worker images
are distroless (no shell — see #distroless-runtime-images), and ECS Exec's
non-interactive command handling against a shell-less container is not a
behavior this project has verified against real AWS. A `run-task` command
override (the same mechanism already proven for `init_db`) avoids that
uncertainty entirely.
"""

import json
import os
import sys
import urllib.error
import urllib.request

TIMEOUT_SECONDS = 5


def _get(target, path):
    # target is an operator-supplied env var (the workflow resolves it from
    # ECS's own DescribeTasks output), never end-user input.
    with urllib.request.urlopen(f"{target}{path}", timeout=TIMEOUT_SECONDS) as resp:  # nosec B310
        return resp.status, resp.read()


def _post_json(target, path, payload):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{target}{path}",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:  # nosec B310
        return resp.status, json.loads(resp.read())


def main():
    target = os.environ.get("SMOKE_TEST_TARGET_URL")
    admin_password = os.environ.get("SEED_ADMIN_PASSWORD")

    if not target:
        print("SMOKE_TEST_TARGET_URL not set — nothing to check")
        return 1
    if not admin_password:
        print("SEED_ADMIN_PASSWORD not set — cannot exercise the login route")
        return 1

    try:
        status, _ = _get(target, "/health")
        if status != 200:
            print(f"/health returned {status}")
            return 1

        status, body = _post_json(target, "/api/v1/auth/login", {"username": "admin", "password": admin_password})
        if status != 200 or "access_token" not in body:
            print(f"/api/v1/auth/login returned {status}: {body}")
            return 1

        print("Smoke test passed: /health OK, admin login returned a valid access token")
        return 0
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError) as e:
        print(f"Smoke test failed: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
