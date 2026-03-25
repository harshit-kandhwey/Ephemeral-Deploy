from flask import request, jsonify
from flask_jwt_extended import jwt_required, get_jwt_identity
from . import api_v1
from ...extensions import db
from ...models.comment import Comment
from ...models.task import Task


@api_v1.route('/tasks/<int:task_id>/comments', methods=['GET'])
@jwt_required()
def get_comments(task_id):
    """Get all comments for a task"""
    task = Task.query.get_or_404(task_id)
    return jsonify({
        'comments': [c.to_dict() for c in task.comments],
        'count': len(task.comments)
    }), 200


@api_v1.route('/tasks/<int:task_id>/comments', methods=['POST'])
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
    user_id = get_jwt_identity()
    task = Task.query.get_or_404(task_id)
    data = request.get_json()

    if not data or 'content' not in data:
        return jsonify({'error': 'Content is required'}), 400

    comment = Comment(
        content=data['content'],
        task_id=task_id,
        author_id=user_id
    )

    db.session.add(comment)
    db.session.commit()

    # Notify task assignee
    if task.assignee_id and task.assignee_id != user_id:
        from ...tasks.email_tasks import send_comment_notification
        send_comment_notification.delay(comment.id, task.assignee_id)

    return jsonify(comment.to_dict()), 201