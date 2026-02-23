from flask import Blueprint
from . import auth, users, teams, projects, tasks, comments

api_v1 = Blueprint('api_v1', __name__)

# Import routes to register them
