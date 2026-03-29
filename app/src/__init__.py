"""
NexusDeploy Project Management API
Main application package
"""

from .app import create_app
from .extensions import db, celery

__version__ = "1.0.0"

__all__ = ["create_app", "db", "celery"]
