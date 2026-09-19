#!/usr/bin/env python3
"""Queue-depth drain gate for blue-green rotation.

Run as a one-off ECS task (worker image, command override, old slot's own
task definition) inside the VPC before reclaiming an old slot's capacity.
See docs/design-decisions.md#per-slot-celery-queues-close-the-worker-version-skew-gap.

Per-slot Celery queues mean a slot's worker is the ONLY consumer of its own
queue — unlike the old shared-queue design, stopping that worker while its
queue still holds tasks orphans them forever, nothing else will ever pick
them up. Exits non-zero (blocking the reclaim) if the queue is not empty OR
if the queue's worker is still actively running/holding a task from it; the
caller is expected to retry/poll rather than treat one non-zero result as
final, since a worker can still be finishing an in-flight batch.
"""

import os
import sys

from celery import Celery
from redis import Redis


def _queue_depth(redis_url, queue_name):
    client = Redis.from_url(redis_url, decode_responses=True)
    # Kombu's redis transport stores a queue as a native Redis list keyed by
    # the queue name (no vhost/exchange prefixing configured here).
    return client.llen(queue_name)


def _in_flight_count(redis_url, queue_name):
    """Tasks the queue's worker has already pulled off the list but not yet
    finished. LLEN alone can't see these: this project's Celery config never
    sets task_acks_late, so the default (early ack) removes a message from
    Redis the moment a worker's prefetch buffer takes it — before the task
    body has actually run. A worker mid-task, or holding a prefetched task,
    would otherwise read as "queue empty" here.

    Returns None (distinct from 0) when no worker replied at all — a
    verification failure, not evidence of an empty queue — so the caller can
    fail closed rather than default to "nothing in flight."
    """
    inspect_app = Celery(broker=redis_url)
    insp = inspect_app.control.inspect(timeout=5)
    active = insp.active()
    reserved = insp.reserved()

    if active is None or reserved is None:
        return None

    count = 0
    for tasks in list(active.values()) + list(reserved.values()):
        for task in tasks:
            routing_key = (task.get("delivery_info") or {}).get("routing_key")
            if routing_key == queue_name:
                count += 1
    return count


def main():
    redis_url = os.environ.get("REDIS_URL")
    queue_name = os.environ.get("CELERY_TASK_QUEUE")

    if not redis_url or not queue_name:
        print("REDIS_URL / CELERY_TASK_QUEUE not set — cannot check queue depth")
        return 1

    try:
        depth = _queue_depth(redis_url, queue_name)
    except Exception as e:
        print(f"Could not check queue depth: {e}")
        return 1

    if depth != 0:
        print(f"Queue '{queue_name}' depth: {depth}")
        return 1

    try:
        in_flight = _in_flight_count(redis_url, queue_name)
    except Exception as e:
        print(f"Could not check in-flight tasks: {e}")
        return 1

    if in_flight is None:
        print("No worker replied to the inspect request — cannot confirm nothing is in flight")
        return 1

    if in_flight:
        print(f"Queue '{queue_name}' depth: 0, but {in_flight} task(s) still in flight on it")
        return 1

    print(f"Queue '{queue_name}' depth: 0, no in-flight tasks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
