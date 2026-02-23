"""
Celery worker entry point
"""
from app.src import create_app
from app.src.extensions import celery

# Create app context for Celery
app = create_app()
app.app_context().push()
