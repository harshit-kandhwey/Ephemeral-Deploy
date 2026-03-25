"""
Celery worker entry point
"""
import os
from . import create_app
from .extensions import celery  # noqa: F401

# Pass ENV explicitly so production validation runs for workers too.
# If ENV=production and SECRET_KEY is missing, the worker logs a clear
# STARTUP FAILED message before raising RuntimeError.
app = create_app(os.getenv('ENV', 'development'))
app.app_context().push()