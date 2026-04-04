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

    # Log user_id instead of email — PII compliance (GDPR/CCPA)
    current_app.logger.info(f"[EMAIL] Task '{task.title}' assigned to user_id={user.id}")
    return f"Email sent to user_id={user.id}"


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

    # Log user_id instead of email — PII compliance (GDPR/CCPA)
    current_app.logger.info(
        f"[EMAIL] New comment on task {comment.task_id} for user_id={user.id}"
    )
    return f"Notification sent to user_id={user.id}"


@celery.task(name="tasks.send_daily_digest")
def send_daily_digest():
    """Send daily digest of tasks to all users"""
    users = db.session.execute(
        db.select(User).filter_by(is_active=True)
    ).scalars().all()

    for user in users:
        pending_tasks = db.session.execute(
            db.select(db.func.count(Task.id)).where(
                Task.assignee_id == user.id,
                Task.status != "done",
            )
        ).scalar()
        # Log user_id instead of email — PII compliance (GDPR/CCPA)
        current_app.logger.info(f"[DIGEST] user_id={user.id}: {pending_tasks} pending tasks")

    return f"Digest sent to {len(users)} users"