import json
from unittest.mock import patch

from src.services.cache_service import CacheService

# Patch target is src.services.cache_service.redis_client, NOT
# src.extensions.redis_client: cache_service does a module-level
# `from ..extensions import redis_client`, binding its own copy at import
# time (None, since nothing in src/ imports src.services today) — patching
# the extensions module never touches that already-bound copy.


def test_get_returns_deserialized_value(app):
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        mock_redis.get.return_value = json.dumps({"a": 1})
        result = CacheService.get("some-key")
    assert result == {"a": 1}


def test_get_returns_none_on_cache_miss(app):
    """The ternary exists specifically so a miss doesn't call json.loads(None)."""
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        mock_redis.get.return_value = None
        result = CacheService.get("missing-key")
    assert result is None


def test_get_swallows_redis_exception_and_returns_none(app):
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        mock_redis.get.side_effect = Exception("boom")
        result = CacheService.get("some-key")
    assert result is None


def test_set_serializes_and_calls_setex_with_expiration(app):
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        ok = CacheService.set("key", {"a": 1}, expiration=60)
    mock_redis.setex.assert_called_once_with("key", 60, json.dumps({"a": 1}))
    assert ok is True


def test_set_default_expiration_is_one_hour(app):
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        CacheService.set("key", "value")
    args, _ = mock_redis.setex.call_args
    assert args[1] == 3600


def test_set_swallows_exception_and_returns_false(app):
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        mock_redis.setex.side_effect = Exception("boom")
        ok = CacheService.set("key", "value")
    assert ok is False


def test_delete_calls_redis_delete_and_returns_true(app):
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        ok = CacheService.delete("key")
    mock_redis.delete.assert_called_once_with("key")
    assert ok is True


def test_delete_swallows_exception_and_returns_false(app):
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        mock_redis.delete.side_effect = Exception("boom")
        ok = CacheService.delete("key")
    assert ok is False


def test_invalidate_pattern_deletes_all_matching_keys(app):
    """Guards the *keys unpacking specifically — delete(keys) instead of
    delete(*keys) would pass a list where redis expects varargs."""
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        mock_redis.keys.return_value = [b"a", b"b"]
        ok = CacheService.invalidate_pattern("prefix:*")
    mock_redis.delete.assert_called_once_with(b"a", b"b")
    assert ok is True


def test_invalidate_pattern_no_keys_found_does_not_call_delete(app):
    """Guards the `if keys:` branch itself — a test only checking "no
    crash" would stay green even if this guard were deleted, since
    redis.delete() with zero args is itself harmless."""
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        mock_redis.keys.return_value = []
        CacheService.invalidate_pattern("prefix:*")
    mock_redis.delete.assert_not_called()


def test_invalidate_pattern_swallows_exception_and_returns_false(app):
    with app.app_context(), patch("src.services.cache_service.redis_client") as mock_redis:
        mock_redis.keys.side_effect = Exception("boom")
        ok = CacheService.invalidate_pattern("prefix:*")
    assert ok is False
