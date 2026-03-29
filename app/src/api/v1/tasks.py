from flask import request, jsonify
from flask_jwt_extended import jwt_required, get_jwt_identity
from datetime import datetime
from . import api_v1
from ...extensions import db
from ...models.task import Task
from ...models.user import User
from ...models.audit_log import AuditLog
from ...utils.decorators import role_required, get_current_user_or_401


@api_v1.route("/tasks", methods=["GET"])
@jwt_required()
def get_tasks():
    """
    Get all tasks with pagination and filtering
    ---
    tags:
      - Tasks
    security:
      - Bearer: []
    parameters:
      - name: page
        in: query
        type: integer
        default: 1
      - name: per_page
        in: query
        type: integer
        default: 20
      - name: status
        in: query
        type: string
      - name: priority
        in: query
        type: string
      - name: project_id
        in: query
        type: integer
      - name: assignee_id
        in: query
        type: integer
    responses:
      200:
        description: List of tasks
    """
    user_id = get_jwt_identity()
    user = User.query.get(user_id)

    if not user:
        return jsonify({"error": "User not found"}), 401

    # Base query
    query = Task.query

    # Filters
    if request.args.get("status"):
        query = query.filter_by(status=request.args.get("status"))

    if request.args.get("priority"):
        query = query.filter_by(priority=request.args.get("priority"))

    if request.args.get("project_id"):
        query = query.filter_by(project_id=request.args.get("project_id"))

    if request.args.get("assignee_id"):
        query = query.filter_by(assignee_id=request.args.get("assignee_id"))

    # If not admin, only show tasks from user's team projects
    if user.role != "admin":
        team_project_ids = [p.id for p in user.team.projects] if user.team else []
        query = query.filter(Task.project_id.in_(team_project_ids))

    # Pagination
    page = request.args.get("page", 1, type=int)
    per_page = min(request.args.get("per_page", 20, type=int), 100)

    tasks = query.order_by(Task.created_at.desc()).paginate(
        page=page, per_page=per_page, error_out=False
    )

    return (
        jsonify(
            {
                "tasks": [task.to_dict() for task in tasks.items],
                "total": tasks.total,
                "pages": tasks.pages,
                "current_page": tasks.page,
            }
        ),
        200,
    )


@api_v1.route("/tasks/<int:task_id>", methods=["GET"])
@jwt_required()
def get_task(task_id):
    """
    Get task by ID
    ---
    tags:
      - Tasks
    security:
      - Bearer: []
    parameters:
      - name: task_id
        in: path
        type: integer
        required: true
    responses:
      200:
        description: Task details
      404:
        description: Task not found
    """
    task = Task.query.get_or_404(task_id)
    return jsonify(task.to_dict(include_comments=True)), 200


@api_v1.route("/tasks", methods=["POST"])
@jwt_required()
def create_task():
    """
    Create a new task
    ---
    tags:
      - Tasks
    security:
      - Bearer: []
    parameters:
      - name: body
        in: body
        required: true
        schema:
          type: object
          required:
            - title
            - project_id
          properties:
            title:
              type: string
            description:
              type: string
            priority:
              type: string
              enum: [low, medium, high, critical]
            project_id:
              type: integer
            assignee_id:
              type: integer
            due_date:
              type: string
              format: date-time
    responses:
      201:
        description: Task created
      400:
        description: Validation error
    """
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    user_id = user.id
    data = request.get_json()

    if not data or "title" not in data or "project_id" not in data:
        return jsonify({"error": "Missing required fields"}), 400

    task = Task(
        title=data["title"],
        description=data.get("description", ""),
        priority=data.get("priority", "medium"),
        project_id=data["project_id"],
        creator_id=user_id,
        assignee_id=data.get("assignee_id"),
    )

    if data.get("due_date"):
        task.due_date = datetime.fromisoformat(data["due_date"])

    db.session.add(task)
    db.session.commit()

    # Audit log
    audit = AuditLog(
        user_id=user_id,
        action="created",
        entity_type="task",
        entity_id=task.id,
        changes={"title": task.title, "project_id": task.project_id},
        ip_address=request.remote_addr,
    )
    db.session.add(audit)
    db.session.commit()

    # Send notification (async)
    if task.assignee_id:
        from ...tasks.email_tasks import send_task_assignment_email

        send_task_assignment_email.delay(task.id, task.assignee_id)

    return jsonify(task.to_dict()), 201


@api_v1.route("/tasks/<int:task_id>", methods=["PUT"])
@jwt_required()
def update_task(task_id):
    """
    Update a task
    ---
    tags:
      - Tasks
    security:
      - Bearer: []
    parameters:
      - name: task_id
        in: path
        type: integer
        required: true
      - name: body
        in: body
        schema:
          type: object
          properties:
            title:
              type: string
            description:
              type: string
            status:
              type: string
            priority:
              type: string
            assignee_id:
              type: integer
    responses:
      200:
        description: Task updated
    """
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    user_id = user.id
    task = Task.query.get_or_404(task_id)
    data = request.get_json()

    changes = {}

    if "title" in data:
        changes["title"] = {"old": task.title, "new": data["title"]}
        task.title = data["title"]

    if "description" in data:
        task.description = data["description"]

    if "status" in data:
        old_status = task.status
        task.status = data["status"]
        changes["status"] = {"old": old_status, "new": data["status"]}

        if data["status"] == "done" and not task.completed_at:
            task.completed_at = datetime.utcnow()

    if "priority" in data:
        changes["priority"] = {"old": task.priority, "new": data["priority"]}
        task.priority = data["priority"]

    if "assignee_id" in data:
        old_assignee = task.assignee_id
        task.assignee_id = data["assignee_id"]
        changes["assignee_id"] = {"old": old_assignee, "new": data["assignee_id"]}

        # Notify new assignee
        if data["assignee_id"] and data["assignee_id"] != old_assignee:
            from ...tasks.email_tasks import send_task_assignment_email

            send_task_assignment_email.delay(task.id, data["assignee_id"])

    db.session.commit()

    # Audit log
    audit = AuditLog(
        user_id=user_id,
        action="updated",
        entity_type="task",
        entity_id=task.id,
        changes=changes,
        ip_address=request.remote_addr,
    )
    db.session.add(audit)
    db.session.commit()

    return jsonify(task.to_dict()), 200


@api_v1.route("/tasks/<int:task_id>", methods=["DELETE"])
@jwt_required()
@role_required(["admin", "manager"])
def delete_task(task_id):
    """
    Delete a task (admin/manager only)
    ---
    tags:
      - Tasks
    security:
      - Bearer: []
    parameters:
      - name: task_id
        in: path
        type: integer
        required: true
    responses:
      200:
        description: Task deleted
    """
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    user_id = user.id
    task = Task.query.get_or_404(task_id)

    # Audit log before deletion
    audit = AuditLog(
        user_id=user_id,
        action="deleted",
        entity_type="task",
        entity_id=task.id,
        changes={"title": task.title},
        ip_address=request.remote_addr,
    )
    db.session.add(audit)

    db.session.delete(task)
    db.session.commit()

    return jsonify({"message": "Task deleted successfully"}), 200
