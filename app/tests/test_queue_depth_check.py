from unittest.mock import MagicMock, patch

from src import queue_depth_check

_SLOT1_QUEUES = {"worker@host": [{"name": "tasks-staging-slot1"}]}


def _mock_inspect(active=None, reserved=None, queues=_SLOT1_QUEUES):
    """Build a mock whose .control.inspect(...) returns an object with the
    given .active_queues()/.active()/.reserved() replies, matching Celery's
    real API shape. queues defaults to one worker consuming slot1's queue."""
    insp = MagicMock()
    insp.active_queues.return_value = queues
    insp.active.return_value = active
    insp.reserved.return_value = reserved
    celery_app = MagicMock()
    celery_app.control.inspect.return_value = insp
    return celery_app


def test_main_fails_without_redis_url(monkeypatch):
    monkeypatch.delenv("CELERY_BROKER_URL", raising=False)
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")
    assert queue_depth_check.main() == 1


def test_main_fails_without_queue_name(monkeypatch):
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.delenv("CELERY_TASK_QUEUE", raising=False)
    assert queue_depth_check.main() == 1


def test_main_returns_zero_when_queue_empty_and_nothing_in_flight(monkeypatch):
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 0

    with (
        patch("src.queue_depth_check.Redis.from_url", return_value=mock_client),
        patch(
            "src.queue_depth_check.Celery",
            return_value=_mock_inspect(active={"worker@host": []}, reserved={"worker@host": []}),
        ),
    ):
        assert queue_depth_check.main() == 0
    mock_client.llen.assert_any_call("tasks-staging-slot1")


def test_main_returns_nonzero_when_queue_has_pending_tasks(monkeypatch):
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 3

    with patch("src.queue_depth_check.Redis.from_url", return_value=mock_client):
        assert queue_depth_check.main() == 1


def test_main_fails_on_connection_error(monkeypatch):
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    with patch("src.queue_depth_check.Redis.from_url", side_effect=ConnectionError("refused")):
        assert queue_depth_check.main() == 1


def test_main_fails_when_task_is_active_on_this_queue(monkeypatch):
    """LLEN alone can't see this: task_acks_late is never set, so the
    default (early ack) removes a message from Redis the instant a worker's
    prefetch buffer takes it — before the task body finishes. An empty
    queue with an active task on it must still block the reclaim."""
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 0
    active_task = {"id": "abc", "delivery_info": {"routing_key": "tasks-staging-slot1"}}

    with (
        patch("src.queue_depth_check.Redis.from_url", return_value=mock_client),
        patch(
            "src.queue_depth_check.Celery",
            return_value=_mock_inspect(active={"worker@host": [active_task]}, reserved={"worker@host": []}),
        ),
    ):
        assert queue_depth_check.main() == 1


def test_main_ignores_active_tasks_on_a_different_queue(monkeypatch):
    """The broker is shared across slots, so inspect() sees every connected
    worker's active tasks — only tasks routed to THIS queue should count."""
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 0
    other_slot_task = {"id": "abc", "delivery_info": {"routing_key": "tasks-staging-slot2"}}

    with (
        patch("src.queue_depth_check.Redis.from_url", return_value=mock_client),
        patch(
            "src.queue_depth_check.Celery",
            return_value=_mock_inspect(active={"worker@host": [other_slot_task]}, reserved={"worker@host": []}),
        ),
    ):
        assert queue_depth_check.main() == 0


def test_main_fails_closed_when_no_worker_replies(monkeypatch):
    """inspect() returns None (not {}) when no node responds within the
    timeout — that's a verification failure, not evidence the queue is
    drained, and must not be treated as "nothing in flight"."""
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 0

    with (
        patch("src.queue_depth_check.Redis.from_url", return_value=mock_client),
        patch("src.queue_depth_check.Celery", return_value=_mock_inspect(active=None, reserved=None, queues=None)),
    ):
        assert queue_depth_check.main() == 1


def test_main_fails_on_inspect_error(monkeypatch):
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 0

    with (
        patch("src.queue_depth_check.Redis.from_url", return_value=mock_client),
        patch("src.queue_depth_check.Celery", side_effect=RuntimeError("broker unreachable")),
    ):
        assert queue_depth_check.main() == 1


def test_main_fails_closed_when_only_another_slots_worker_replies(monkeypatch):
    """The broker is shared: slot2's worker answering says nothing about
    slot1's worker, which may be down with tasks still reserved. Must not
    read as "nothing in flight"."""
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 0
    other = {"worker2@host": []}

    with (
        patch("src.queue_depth_check.Redis.from_url", return_value=mock_client),
        patch(
            "src.queue_depth_check.Celery",
            return_value=_mock_inspect(
                active=other, reserved=other, queues={"worker2@host": [{"name": "tasks-staging-slot2"}]}
            ),
        ),
    ):
        assert queue_depth_check.main() == 1


def test_main_fails_closed_when_target_worker_misses_a_reply(monkeypatch):
    """Worker answered active_queues() but not reserved()/active() (e.g. timed
    out under load) while another slot's worker did — unverified, so block."""
    monkeypatch.setenv("CELERY_BROKER_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 0

    with (
        patch("src.queue_depth_check.Redis.from_url", return_value=mock_client),
        patch(
            "src.queue_depth_check.Celery",
            return_value=_mock_inspect(active={"worker2@host": []}, reserved={"worker2@host": []}),
        ),
    ):
        assert queue_depth_check.main() == 1


def test_in_flight_count_queries_reserved_before_active():
    """reserved -> active is one-way, so reserved must be read first."""
    order = []
    insp = MagicMock()
    insp.active_queues.return_value = _SLOT1_QUEUES
    insp.reserved.side_effect = lambda: order.append("reserved") or {"worker@host": []}
    insp.active.side_effect = lambda: order.append("active") or {"worker@host": []}
    celery_app = MagicMock()
    celery_app.control.inspect.return_value = insp

    with patch("src.queue_depth_check.Celery", return_value=celery_app):
        assert queue_depth_check._in_flight_count("redis://x", "tasks-staging-slot1") == 0
    assert order == ["reserved", "active"]


def test_queue_depth_counts_priority_lists():
    """Kombu puts a prioritised task on name + sep + step, not the base key;
    LLEN on the base key alone would read an occupied queue as empty."""
    lists = {"tasks-staging-slot13": 2}
    mock_client = MagicMock()
    mock_client.llen.side_effect = lambda key: lists.get(key, 0)

    with patch("src.queue_depth_check.Redis.from_url", return_value=mock_client):
        assert queue_depth_check._queue_depth("redis://x", "tasks-staging-slot1") == 2
