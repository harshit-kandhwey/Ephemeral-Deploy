from flask import current_app
from ..extensions import celery
from ..models.task import Task
from ..models.user import User
from ..models.comment import Comment


@celery.task(name='tasks.send_task_assignment_email')
def send_task_assignment_email(task_id, user_id):
    """Send email when a task is assigned"""
    task = Task.query.get(task_id)
    user = User.query.get(user_id)

    if not task or not user:
        current_app.logger.warning(
            f"send_task_assignment_email: task {task_id} or user {user_id} not found"
        )
        return

    current_app.logger.info(
        f"[EMAIL] Task '{task.title}' assigned to {user.email}"
    )

    return f"Email sent to {user.email}"


@celery.task(name='tasks.send_comment_notification')
def send_comment_notification(comment_id, user_id):
    """Send email when someone comments on your task"""
    comment = Comment.query.get(comment_id)
    user = User.query.get(user_id)

    if not comment or not user:
        current_app.logger.warning(
            f"send_comment_notification: comment {comment_id} or user {user_id} not found"
        )
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
        # BUG FIX: 'status' values in the Task model are 'todo', 'in_progress',
        # 'in_review', 'done'. The digest only counted 'todo' tasks, silently
        # ignoring 'in_progress' and 'in_review'. Count all non-done tasks so the
        # digest reflects actual pending work.
        pending_tasks = Task.query.filter(
            Task.assignee_id == user.id,
            Task.status != 'done'
        ).count()

        current_app.logger.info(
            f"[DIGEST] {user.email}: {pending_tasks} pending tasks"
        )

    return f"Digest sent to {len(users)} users"
