from functools import wraps

from flask import jsonify
from flask_jwt_extended import get_jwt_identity

from ..extensions import db
from ..models.user import User


def get_current_user_or_401():
    """
    Fetch current user from JWT identity or return a 401 error response.
    Returns:
        tuple: (user, error_response) where one is None
        - On success: (User, None)
        - On failure: (None, (error_json, 401))
    """
    try:
        user_id = int(get_jwt_identity())
    except (ValueError, TypeError):
        return None, (jsonify({"error": "Invalid authentication"}), 401)

    user = db.session.get(User, user_id)
    if not user:
        return None, (jsonify({"error": "User not found"}), 401)

    return user, None


def role_required(roles):
    """
    Decorator to require specific roles.
    Reuses get_current_user_or_401() to avoid duplicating JWT/user lookup logic.
    Usage: @role_required(['admin', 'manager'])
    """

    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            user, error_response = get_current_user_or_401()
            if error_response:
                return error_response

            if user.role not in roles:
                return (
                    jsonify({"error": "Insufficient permissions", "required_roles": roles}),
                    403,
                )

            return f(*args, **kwargs)

        return wrapper

    return decorator
