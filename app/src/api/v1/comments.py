from flask import jsonify, request
from flask_jwt_extended import jwt_required

from ...extensions import db
from ...models.comment import Comment
from ...models.task import Task
from ...utils.decorators import get_current_user_or_401
from ...utils.validation import ValidationError, get_json_body, require_fields
from . import api_v1


@api_v1.route("/tasks/<int:task_id>/comments", methods=["GET"])
@jwt_required()
def get_comments(task_id):
    """Get all comments for a task"""
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    task = Task.query.get_or_404(task_id)

    if user.role != "admin" and (not user.team or task.project.team_id != user.team.id):
        return jsonify({"error": "Access denied"}), 403

    return (
        jsonify(
            {
                "comments": [c.to_dict() for c in task.comments],
                "count": len(task.comments),
            }
        ),
        200,
    )


@api_v1.route("/tasks/<int:task_id>/comments", methods=["POST"])
@jwt_required()
def create_comment(task_id):
    """
    Add a comment to a task
    ---
    tags:
      - Comments
    security:
      - Bearer: []
    parameters:
      - name: task_id
        in: path
        type: integer
        required: true
      - name: body
        in: body
        required: true
        schema:
          type: object
          required:
            - content
          properties:
            content:
              type: string
    responses:
      201:
        description: Comment created
    """
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response

    user_id = user.id
    task = Task.query.get_or_404(task_id)

    if user.role != "admin" and (not user.team or task.project.team_id != user.team.id):
        return jsonify({"error": "Access denied"}), 403

    try:
        data = get_json_body(request, required=True)
        require_fields(data, "content")
    except ValidationError as e:
        return jsonify({"error": e.message}), 400

    comment = Comment(content=data["content"], task_id=task_id, author_id=user_id)

    db.session.add(comment)
    db.session.commit()

    # Notify task assignee
    if task.assignee_id and task.assignee_id != user_id:
        from ...tasks.email_tasks import send_comment_notification

        send_comment_notification.delay(comment.id, task.assignee_id)

    return jsonify(comment.to_dict()), 201
