"""
WSGI entry point for the application
This is what Gunicorn will run
"""

import os
from . import create_app

# Get environment from ENV variable, default to production
config_name = os.getenv("ENV", "production")
app = create_app(config_name)

if __name__ == "__main__":
    app.run()
