from functools import wraps
from flask import jsonify
from flask_jwt_extended import get_jwt_identity
from app.src.models.user import User


def role_required(roles):
    """
    Decorator to require specific roles
    Usage: @role_required(['admin', 'manager'])
    """
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            user_id = get_jwt_identity()
            user = User.query.get(user_id)

            if not user or user.role not in roles:
                return jsonify({
                    'error': 'Insufficient permissions',
                    'required_roles': roles
                }), 403

            return f(*args, **kwargs)
        return wrapper
    return decorator
