from flask import current_app
import json
from ..extensions import redis_client


class CacheService:
    @staticmethod
    def get(key):
        """Get value from cache"""
        try:
            value = redis_client.get(key)
            return json.loads(value) if value else None
        except Exception as e:
            current_app.logger.error(f"Cache get error: {e}")
            return None

    @staticmethod
    def set(key, value, expiration=3600):
        """Set value in cache with expiration (default 1 hour)"""
        try:
            redis_client.setex(
                key,
                expiration,
                json.dumps(value)
            )
            return True
        except Exception as e:
            current_app.logger.error(f"Cache set error: {e}")
            return False

    @staticmethod
    def delete(key):
        """Delete key from cache"""
        try:
            redis_client.delete(key)
            return True
        except Exception as e:
            current_app.logger.error(f"Cache delete error: {e}")
            return False

    @staticmethod
    def invalidate_pattern(pattern):
        """Delete all keys matching pattern"""
        try:
            keys = redis_client.keys(pattern)
            if keys:
                redis_client.delete(*keys)
            return True
        except Exception as e:
            current_app.logger.error(f"Cache invalidate error: {e}")
            return False
