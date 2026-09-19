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
        current_app.logger.warning(f"send_task_assignment_email: task {task_id} or user {user_id} not found")
        return

    # No real email provider is wired in yet — this only logs. Wording is
    # deliberately "logged", not "sent", so the return value can never be
    # mistaken for delivery evidence once a real provider lands.
    # Log user_id instead of email — PII compliance (GDPR/CCPA)
    current_app.logger.info(f"[EMAIL-STUB] Task '{task.title}' assignment logged for user_id={user.id}")
    return f"Assignment notification logged for user_id={user.id} (no email provider configured)"


@celery.task(name="tasks.send_comment_notification")
def send_comment_notification(comment_id, user_id):
    """Send email when someone comments on your task"""
    comment = db.session.get(Comment, comment_id)
    user = db.session.get(User, user_id)

    if not comment or not user:
        current_app.logger.warning(f"send_comment_notification: comment {comment_id} or user {user_id} not found")
        return

    # No real email provider is wired in yet — this only logs, see the
    # matching comment in send_task_assignment_email above.
    # Log user_id instead of email — PII compliance (GDPR/CCPA)
    current_app.logger.info(f"[EMAIL-STUB] New comment on task {comment.task_id} logged for user_id={user.id}")
    return f"Comment notification logged for user_id={user.id} (no email provider configured)"


@celery.task(name="tasks.send_daily_digest")
def send_daily_digest():
    """Log daily digest of tasks for all users (no real email provider wired in yet)"""
    users = db.session.execute(db.select(User).filter_by(is_active=True)).scalars().all()

    # One grouped query instead of one COUNT per user (was a textbook N+1).
    pending_counts = dict(
        db.session.execute(
            db.select(Task.assignee_id, db.func.count(Task.id)).where(Task.status != "done").group_by(Task.assignee_id)
        ).all()
    )

    for user in users:
        pending_tasks = pending_counts.get(user.id, 0)
        # Log user_id instead of email — PII compliance (GDPR/CCPA)
        current_app.logger.info(f"[DIGEST-STUB] user_id={user.id}: {pending_tasks} pending tasks")

    return f"Digest logged for {len(users)} users (no email provider configured)"
