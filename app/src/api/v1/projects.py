from flask import jsonify, request
from flask_jwt_extended import get_jwt_identity, jwt_required

from ...extensions import db
from ...models.audit_log import AuditLog
from ...models.project import Project
from ...utils.decorators import get_current_user_or_401, role_required
from . import api_v1


def _get_real_ip():
    """Return client IP address.

    Behind a load balancer, configure Flask's ProxyFix middleware in app.py:
        from werkzeug.middleware.proxy_fix import ProxyFix
        app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)

    With ProxyFix configured, request.remote_addr is already set to the real
    client IP by the time this runs — no manual X-Forwarded-For parsing needed.
    Without ProxyFix, reading X-Forwarded-For directly is an IP spoofing risk
    because any client can set that header.

    For this project (ECS behind no public ALB), remote_addr is safe as-is.
    """
    return request.remote_addr


@api_v1.route("/projects", methods=["GET"])
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
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    if user.role == "admin":
        projects = Project.query.all()
    elif user.team:
        projects = user.team.projects
    else:
        projects = []

    return jsonify({"projects": [p.to_dict() for p in projects], "count": len(projects)}), 200


@api_v1.route("/projects/<int:project_id>", methods=["GET"])
@jwt_required()
def get_project(project_id):
    """Get project by ID"""
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    project = db.get_or_404(Project, project_id)

    # Enforce team-based access — admins see all, others only their team's projects
    if user.role != "admin" and (not user.team or project.team_id != user.team.id):
        return jsonify({"error": "Access denied"}), 403

    return jsonify(project.to_dict()), 200


@api_v1.route("/projects", methods=["POST"])
@jwt_required()
@role_required(["admin", "manager"])
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

    if not data or "name" not in data or "team_id" not in data:
        return jsonify({"error": "Missing required fields"}), 400

    project = Project(
        name=data["name"],
        description=data.get("description", ""),
        team_id=data["team_id"],
    )

    db.session.add(project)
    db.session.flush()  # assigns project.id without committing

    audit = AuditLog(
        user_id=user_id,
        action="created",
        entity_type="project",
        entity_id=project.id,
        changes={"name": project.name, "team_id": project.team_id},
        ip_address=_get_real_ip(),
    )
    db.session.add(audit)
    db.session.commit()

    return jsonify(project.to_dict()), 201


@api_v1.route("/projects/<int:project_id>", methods=["PUT"])
@jwt_required()
@role_required(["admin", "manager"])
def update_project(project_id):
    """
    Update a project (manager/admin only)
    ---
    tags:
      - Projects
    security:
      - Bearer: []
    parameters:
      - name: project_id
        in: path
        type: integer
        required: true
      - name: body
        in: body
        schema:
          type: object
          properties:
            name:
              type: string
            description:
              type: string
            status:
              type: string
    responses:
      200:
        description: Project updated
    """
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    project = db.get_or_404(Project, project_id)

    # Admins can update any project; managers only their team's projects
    if user.role != "admin" and (not user.team or project.team_id != user.team.id):
        return jsonify({"error": "Access denied"}), 403

    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "No data provided"}), 400

    changes = {}
    if "name" in data:
        changes["name"] = {"old": project.name, "new": data["name"]}
        project.name = data["name"]
    if "description" in data:
        changes["description"] = {"old": project.description, "new": data["description"]}
        project.description = data["description"]
    if "status" in data:
        changes["status"] = {"old": project.status, "new": data["status"]}
        project.status = data["status"]

    db.session.flush()  # persist changes without committing

    # Only write audit log when something actually changed
    if changes:
        audit = AuditLog(
            user_id=user.id,
            action="updated",
            entity_type="project",
            entity_id=project.id,
            changes=changes,
            ip_address=_get_real_ip(),
        )
        db.session.add(audit)

    db.session.commit()
    return jsonify(project.to_dict()), 200
