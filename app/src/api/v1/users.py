from flask import request, jsonify
from flask_jwt_extended import jwt_required, get_jwt_identity
from . import api_v1
from ...extensions import db
from ...models.user import User
from ...models.team import Team
from ...utils.decorators import role_required


@api_v1.route('/users', methods=['GET'])
@jwt_required()
@role_required(['admin', 'manager'])
def get_users():
    """
    Get all users (admin/manager only)
    ---
    tags:
      - Users
    security:
      - Bearer: []
    responses:
      200:
        description: List of users
    """
    users = User.query.all()
    return jsonify({
        'users': [u.to_dict(include_email=True) for u in users],
        'count': len(users)
    }), 200


@api_v1.route('/users/<int:user_id>', methods=['GET'])
@jwt_required()
def get_user(user_id):
    """Get user by ID"""
    try:
        current_user_id = int(get_jwt_identity())
    except (ValueError, TypeError):
        return jsonify({'error': 'Invalid authentication'}), 400
    current_user = User.query.get_or_404(current_user_id)
    user = User.query.get_or_404(user_id)
    # Only include email for admins/managers or the user themselves
    include_email = current_user.role in (
        'admin', 'manager') or current_user_id == user_id
    return jsonify(user.to_dict(include_email=include_email)), 200


@api_v1.route('/users/<int:user_id>', methods=['PUT'])
@jwt_required()
def update_user(user_id):
    """Update user profile"""
    try:
        current_user_id = int(get_jwt_identity())
    except (ValueError, TypeError):
        return jsonify({'error': 'Invalid authentication'}), 400
    current_user = User.query.get_or_404(current_user_id)
    user = User.query.get_or_404(user_id)

    # Users can only update themselves; admins can update anyone
    if current_user_id != user_id and current_user.role != 'admin':
        return jsonify({'error': 'Insufficient permissions'}), 403

    data = request.get_json()
    if not data:
        return jsonify({'error': 'No data provided'}), 400

    if 'full_name' in data:
        user.full_name = data['full_name']

    if 'password' in data:
        user.set_password(data['password'])

    # Only admins may change roles or active status
    if current_user.role == 'admin':
        if 'role' in data:
            allowed_roles = ['admin', 'manager', 'developer']
            if data['role'] not in allowed_roles:
                return jsonify({'error': f'Invalid role. Must be one of: {", ".join(allowed_roles)}'}), 400
            user.role = data['role']

        if 'is_active' in data:
            if not isinstance(data['is_active'], bool):
                return jsonify({'error': 'is_active must be a boolean'}), 400
            user.is_active = data['is_active']

        if 'team_id' in data:
            team_id = data['team_id']
            if team_id is not None:
                # Validate team_id is an integer
                try:
                    team_id = int(team_id)
                except (ValueError, TypeError):
                    return jsonify({'error': 'team_id must be an integer'}), 400

                team = Team.query.get(team_id)
                if not team:
                    return jsonify({'error': f'Team with id {team_id} does not exist'}), 400
            user.team_id = team_id

    db.session.commit()
    return jsonify(user.to_dict(include_email=True)), 200


@api_v1.route('/users/<int:user_id>', methods=['DELETE'])
@jwt_required()
@role_required(['admin'])
def delete_user(user_id):
    """Deactivate a user (admin only) — soft delete"""
    user = User.query.get_or_404(user_id)
    user.is_active = False
    db.session.commit()
    return jsonify({'message': 'User deactivated'}), 200