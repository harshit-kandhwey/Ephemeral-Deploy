from flask import current_app
from app.src.extensions import celery
from app.src.models.task import Task
from app.src.models.user import User
from app.src.models.comment import Comment


@celery.task(name='tasks.send_task_assignment_email')
def send_task_assignment_email(task_id, user_id):
    """Send email when a task is assigned"""
    task = Task.query.get(task_id)
    user = User.query.get(user_id)

    if not task or not user:
        return

    # In production, use actual email service (SES, SendGrid, etc.)
    current_app.logger.info(
        f"[EMAIL] Task '{task.title}' assigned to {user.email}"
    )

    # Simulate email sending
    # send_email(
    #     to=user.email,
    #     subject=f"New Task Assigned: {task.title}",
    #     body=f"You have been assigned task: {task.title}\n\n{task.description}"
    # )

    return f"Email sent to {user.email}"


@celery.task(name='tasks.send_comment_notification')
def send_comment_notification(comment_id, user_id):
    """Send email when someone comments on your task"""
    comment = Comment.query.get(comment_id)
    user = User.query.get(user_id)

    if not comment or not user:
        return

    current_app.logger.info(
        f"[EMAIL] New comment on task {comment.task_id} for {user.email}"
    )

    return f"Notification sent to {user.email}"


@celery.task(name='tasks.send_daily_digest')
def send_daily_digest():
    """Send daily digest of tasks to all users"""
    users = User.query.filter_by(is_active=True).all()

    for user in users:
        # Get user's pending tasks
        pending_tasks = Task.query.filter_by(
            assignee_id=user.id,
            status='todo'
        ).count()

        current_app.logger.info(
            f"[DIGEST] {user.email}: {pending_tasks} pending tasks"
        )

    return f"Digest sent to {len(users)} users"
