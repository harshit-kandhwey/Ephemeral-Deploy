#!/usr/bin/env python3
"""Queue-depth drain gate for blue-green rotation.

Run as a one-off ECS task (worker image, command override, old slot's own
task definition) inside the VPC before reclaiming an old slot's capacity.
See docs/design-decisions.md#per-slot-celery-queues-close-the-worker-version-skew-gap.

Per-slot Celery queues mean a slot's worker is the ONLY consumer of its own
queue — unlike the old shared-queue design, stopping that worker while its
queue still holds tasks orphans them forever, nothing else will ever pick
them up. Exits non-zero (blocking the reclaim) if the queue is not empty;
the caller is expected to retry/poll rather than treat one non-zero result
as final, since a worker can still be finishing an in-flight batch.
"""

import os
import sys

from redis import Redis


def main():
    redis_url = os.environ.get("REDIS_URL")
    queue_name = os.environ.get("CELERY_TASK_QUEUE")

    if not redis_url or not queue_name:
        print("REDIS_URL / CELERY_TASK_QUEUE not set — cannot check queue depth")
        return 1

    try:
        client = Redis.from_url(redis_url, decode_responses=True)
        # Kombu's redis transport stores a queue as a native Redis list keyed
        # by the queue name (no vhost/exchange prefixing configured here).
        depth = client.llen(queue_name)
    except Exception as e:
        print(f"Could not check queue depth: {e}")
        return 1

    print(f"Queue '{queue_name}' depth: {depth}")
    return 0 if depth == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
