from unittest.mock import MagicMock, patch

from src import queue_depth_check


def test_main_fails_without_redis_url(monkeypatch):
    monkeypatch.delenv("REDIS_URL", raising=False)
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")
    assert queue_depth_check.main() == 1


def test_main_fails_without_queue_name(monkeypatch):
    monkeypatch.setenv("REDIS_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.delenv("CELERY_TASK_QUEUE", raising=False)
    assert queue_depth_check.main() == 1


def test_main_returns_zero_when_queue_is_empty(monkeypatch):
    monkeypatch.setenv("REDIS_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 0

    with patch("src.queue_depth_check.Redis.from_url", return_value=mock_client):
        assert queue_depth_check.main() == 0
    mock_client.llen.assert_called_once_with("tasks-staging-slot1")


def test_main_returns_nonzero_when_queue_has_pending_tasks(monkeypatch):
    monkeypatch.setenv("REDIS_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    mock_client = MagicMock()
    mock_client.llen.return_value = 3

    with patch("src.queue_depth_check.Redis.from_url", return_value=mock_client):
        assert queue_depth_check.main() == 1


def test_main_fails_on_connection_error(monkeypatch):
    monkeypatch.setenv("REDIS_URL", "redis://10.0.0.1:6379/0")
    monkeypatch.setenv("CELERY_TASK_QUEUE", "tasks-staging-slot1")

    with patch("src.queue_depth_check.Redis.from_url", side_effect=ConnectionError("refused")):
        assert queue_depth_check.main() == 1
