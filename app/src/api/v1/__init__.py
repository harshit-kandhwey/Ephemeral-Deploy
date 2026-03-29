from flask import Blueprint

# CREATE the blueprint FIRST
api_v1 = Blueprint("api_v1", __name__)

# THEN import the routes (they will register themselves on api_v1)
# Import AFTER blueprint creation to avoid circular imports
from . import auth, comments, projects, tasks, teams, users  # noqa: F401, E402

# This allows other modules to do: from app.src.api.v1 import api_v1
