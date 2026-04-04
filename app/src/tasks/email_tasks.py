from flask import current_app

from ..extensions import celery, db
from ..models.comment import Comment
from ..models.task import Task
from ..models.user import User


@celery.task(name="tasks.send_task_assignment_email")
def send_task_assignment_email(task_id, user_id):
    """Send email when a task is assigned"""
    task = db.session.get(Task, task_id)
    user = db.session.get(User, user_id)

    if not task or not user:
        current_app.logger.warning(
            f"send_task_assignment_email: task {task_id} or user {user_id} not found"
        )
        return

    current_app.logger.info(f"[EMAIL] Task '{task.title}' assigned to {user.email}")
    return f"Email sent to {user.email}"


@celery.task(name="tasks.send_comment_notification")
def send_comment_notification(comment_id, user_id):
    """Send email when someone comments on your task"""
    comment = db.session.get(Comment, comment_id)
    user = db.session.get(User, user_id)

    if not comment or not user:
        current_app.logger.warning(
            f"send_comment_notification: comment {comment_id} or user {user_id} not found"
        )
        return

    current_app.logger.info(
        f"[EMAIL] New comment on task {comment.task_id} for {user.email}"
    )
    return f"Notification sent to {user.email}"


@celery.task(name="tasks.send_daily_digest")
def send_daily_digest():
    """Send daily digest of tasks to all users"""
    users = User.query.filter_by(is_active=True).all()

    for user in users:
        pending_tasks = Task.query.filter(
            Task.assignee_id == user.id,
            Task.status != "done",
        ).count()
        current_app.logger.info(f"[DIGEST] {user.email}: {pending_tasks} pending tasks")

    return f"Digest sent to {len(users)} users"
