"""
WSGI entry point for the application
This is what Gunicorn will run
"""

import os
import sys

# When gunicorn uses --chdir src, the working directory is /app/src
# and wsgi is loaded as a top-level module (not src.wsgi), so relative
# imports like 'from . import create_app' fail.
# Fix: ensure /app is on sys.path and use absolute import.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from src.app import create_app  # noqa: E402

# Get environment from ENV variable, default to production
config_name = os.getenv("ENV", "production")
app = create_app(config_name)

if __name__ == "__main__":
    app.run()
