from datetime import datetime

from flask import jsonify, request
from flask_jwt_extended import jwt_required

from ...extensions import db
from ...models.audit_log import AuditLog
from ...models.project import Project
from ...models.task import Task
from ...models.user import User
from ...utils.decorators import get_current_user_or_401, role_required
from ...utils.validation import (
    TASK_PRIORITIES,
    TASK_STATUSES,
    ValidationError,
    get_json_body,
    parse_datetime,
    require_fields,
    resolve_entity,
    validate_choice,
)
from . import api_v1


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
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    # Base query
    query = Task.query

    # Filters. The id filters are coerced with type=int: passing the raw string
    # through to the query sends a non-numeric value to an integer column, which
    # Postgres rejects with a DataError — a 500 for what is really a bad request.
    if request.args.get("status"):
        query = query.filter_by(status=request.args.get("status"))

    if request.args.get("priority"):
        query = query.filter_by(priority=request.args.get("priority"))

    if request.args.get("project_id"):
        project_id = request.args.get("project_id", type=int)
        if project_id is None:
            return jsonify({"error": "project_id must be an integer"}), 400
        query = query.filter_by(project_id=project_id)

    if request.args.get("assignee_id"):
        assignee_id = request.args.get("assignee_id", type=int)
        if assignee_id is None:
            return jsonify({"error": "assignee_id must be an integer"}), 400
        query = query.filter_by(assignee_id=assignee_id)

    # If not admin, only show tasks from user's team projects
    if user.role != "admin":
        team_project_ids = [p.id for p in user.team.projects] if user.team else []
        query = query.filter(Task.project_id.in_(team_project_ids))

    # Pagination
    page = max(request.args.get("page", 1, type=int) or 1, 1)
    per_page = max(1, min(request.args.get("per_page", 20, type=int) or 20, 100))

    tasks = query.order_by(Task.created_at.desc()).paginate(page=page, per_page=per_page, error_out=False)

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
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    task = Task.query.get_or_404(task_id)

    if user.role != "admin" and (not user.team or task.project.team_id != user.team.id):
        return jsonify({"error": "Access denied"}), 403

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

    try:
        data = get_json_body(request, required=True)
        require_fields(data, "title", "project_id")

        # Resolve the project first: an unknown project_id would otherwise reach
        # the DB as a foreign-key violation (500) instead of a 400.
        project = resolve_entity(db.session, Project, data["project_id"], "project_id")

        priority = validate_choice(data.get("priority", "medium"), TASK_PRIORITIES, "priority")
        status = validate_choice(data.get("status", "todo"), TASK_STATUSES, "status")

        assignee_id = None
        if data.get("assignee_id") is not None:
            assignee_id = resolve_entity(db.session, User, data["assignee_id"], "assignee_id").id

        due_date = parse_datetime(data["due_date"], "due_date") if data.get("due_date") else None
    except ValidationError as e:
        return jsonify({"error": e.message}), 400

    if user.role != "admin" and (not user.team or project.team_id != user.team.id):
        return jsonify({"error": "Access denied"}), 403

    task = Task(
        title=data["title"],
        description=data.get("description", ""),
        priority=priority,
        status=status,
        project_id=project.id,
        creator_id=user_id,
        assignee_id=assignee_id,
        due_date=due_date,
    )

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

    if user.role != "admin" and (not user.team or task.project.team_id != user.team.id):
        return jsonify({"error": "Access denied"}), 403

    # A body of `null` parses to None, and `"title" in None` raises TypeError —
    # a 500 on what is simply an empty request.
    try:
        data = get_json_body(request, required=True)

        # Validate everything before mutating the task, so a bad field late in
        # the body cannot leave the task half-updated.
        if "status" in data:
            validate_choice(data["status"], TASK_STATUSES, "status")
        if "priority" in data:
            validate_choice(data["priority"], TASK_PRIORITIES, "priority")
        if "due_date" in data and data["due_date"] is not None:
            parse_datetime(data["due_date"], "due_date")
        if data.get("assignee_id") is not None:
            resolve_entity(db.session, User, data["assignee_id"], "assignee_id")
    except ValidationError as e:
        return jsonify({"error": e.message}), 400

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

    if "due_date" in data:
        task.due_date = parse_datetime(data["due_date"], "due_date") if data["due_date"] else None

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

    # role_required already gate-kept admin/manager, but a manager may only act
    # within their own team — otherwise a manager of one team can delete another
    # team's tasks. Mirror the scoping used by get_task/update_task.
    if user.role != "admin" and (not user.team or task.project.team_id != user.team.id):
        return jsonify({"error": "Access denied"}), 403

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
