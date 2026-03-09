from flask import request, jsonify
from flask_jwt_extended import jwt_required, get_jwt_identity
from . import api_v1
from ...extensions import db
from ...models.project import Project
from ...models.user import User
from ...models.audit_log import AuditLog
from ...utils.decorators import role_required


@api_v1.route('/projects', methods=['GET'])
@jwt_required()
def get_projects():
    """
    Get all projects
    ---
    tags:
      - Projects
    security:
      - Bearer: []
    responses:
      200:
        description: List of projects
    """
    user_id = get_jwt_identity()
    user = User.query.get(user_id)

    if not user:
        return jsonify({'error': 'User not found'}), 401

    if user.role == 'admin':
        projects = Project.query.all()
    elif user.team:
        projects = user.team.projects
    else:
        projects = []

    return jsonify({
        'projects': [p.to_dict() for p in projects],
        'count': len(projects)
    }), 200


@api_v1.route('/projects/<int:project_id>', methods=['GET'])
@jwt_required()
def get_project(project_id):
    """Get project by ID"""
    project = Project.query.get_or_404(project_id)
    return jsonify(project.to_dict()), 200


@api_v1.route('/projects', methods=['POST'])
@jwt_required()
@role_required(['admin', 'manager'])
def create_project():
    """
    Create a new project (manager/admin only)
    ---
    tags:
      - Projects
    security:
      - Bearer: []
    parameters:
      - name: body
        in: body
        required: true
        schema:
          type: object
          required:
            - name
            - team_id
          properties:
            name:
              type: string
            description:
              type: string
            team_id:
              type: integer
    responses:
      201:
        description: Project created
    """
    user_id = get_jwt_identity()
    data = request.get_json()

    if not data or 'name' not in data or 'team_id' not in data:
        return jsonify({'error': 'Missing required fields'}), 400

    project = Project(
        name=data['name'],
        description=data.get('description', ''),
        team_id=data['team_id']
    )

    db.session.add(project)
    db.session.commit()

    # Audit log
    audit = AuditLog(
        user_id=user_id,
        action='created',
        entity_type='project',
        entity_id=project.id,
        changes={'name': project.name, 'team_id': project.team_id}
    )
    db.session.add(audit)
    db.session.commit()

    return jsonify(project.to_dict()), 201


@api_v1.route('/projects/<int:project_id>', methods=['PUT'])
@jwt_required()
@role_required(['admin', 'manager'])
def update_project(project_id):
    """Update project"""
    user_id = get_jwt_identity()
    project = Project.query.get_or_404(project_id)
    data = request.get_json()

    changes = {}

    if 'name' in data:
        changes['name'] = {'old': project.name, 'new': data['name']}
        project.name = data['name']

    if 'description' in data:
        project.description = data['description']

    if 'status' in data:
        changes['status'] = {'old': project.status, 'new': data['status']}
        project.status = data['status']

    db.session.commit()

    audit = AuditLog(
        user_id=user_id,
        action='updated',
        entity_type='project',
        entity_id=project.id,
        changes=changes
    )
    db.session.add(audit)
    db.session.commit()

    return jsonify(project.to_dict()), 200
