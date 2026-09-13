import logging

from src.extensions import db
from src.models.comment import Comment
from src.models.project import Project
from src.models.task import Task
from src.models.team import Team
from src.models.user import User
from src.tasks.email_tasks import send_comment_notification, send_daily_digest, send_task_assignment_email

# @celery.task-decorated functions remain synchronously callable without a
# broker — calling them directly (not .delay()) is how these are unit tested.


def _make_team_and_user(email="dev@example.com", username="dev", is_active=True):
    # Team.name is unique — each call gets its own team so tests needing
    # more than one user don't collide on "Engineering".
    team = Team(name=f"Team-{username}")
    db.session.add(team)
    db.session.commit()
    user = User(email=email, username=username, full_name="A Dev", team_id=team.id, is_active=is_active)
    user.set_password("password123")
    db.session.add(user)
    db.session.commit()
    return team, user


def _make_task(team, user, status="todo"):
    project = Project(name="Proj", team_id=team.id)
    db.session.add(project)
    db.session.commit()
    task = Task(title="Some task", status=status, project_id=project.id, creator_id=user.id, assignee_id=user.id)
    db.session.add(task)
    db.session.commit()
    return task


def test_send_task_assignment_email_logs_and_returns_confirmation_without_leaking_email(app, caplog):
    with app.app_context():
        team, user = _make_team_and_user()
        task = _make_task(team, user)

        with caplog.at_level(logging.INFO):
            result = send_task_assignment_email(task.id, user.id)

        assert f"user_id={user.id}" in result
        assert user.email not in result
        assert user.email not in caplog.text


def test_send_task_assignment_email_missing_task_returns_none_and_warns(app, caplog):
    with app.app_context():
        _, user = _make_team_and_user()

        with caplog.at_level(logging.WARNING):
            result = send_task_assignment_email(999999, user.id)

        assert result is None
        assert any(r.levelno == logging.WARNING for r in caplog.records)


def test_send_task_assignment_email_missing_user_returns_none_and_warns(app, caplog):
    with app.app_context():
        team, user = _make_team_and_user()
        task = _make_task(team, user)

        with caplog.at_level(logging.WARNING):
            result = send_task_assignment_email(task.id, 999999)

        assert result is None
        assert any(r.levelno == logging.WARNING for r in caplog.records)


def test_send_comment_notification_logs_and_returns_confirmation_without_leaking_email(app, caplog):
    with app.app_context():
        team, user = _make_team_and_user()
        task = _make_task(team, user)
        comment = Comment(content="nice work", task_id=task.id, author_id=user.id)
        db.session.add(comment)
        db.session.commit()

        with caplog.at_level(logging.INFO):
            result = send_comment_notification(comment.id, user.id)

        assert f"user_id={user.id}" in result
        assert user.email not in result
        assert user.email not in caplog.text
        assert str(task.id) in caplog.text


def test_send_comment_notification_missing_comment_or_user_returns_none(app):
    with app.app_context():
        _, user = _make_team_and_user()
        assert send_comment_notification(999999, user.id) is None

        team, user2 = _make_team_and_user(email="u2@example.com", username="u2")
        task = _make_task(team, user2)
        comment = Comment(content="x", task_id=task.id, author_id=user2.id)
        db.session.add(comment)
        db.session.commit()
        assert send_comment_notification(comment.id, 999999) is None


def test_send_daily_digest_only_counts_active_users(app, caplog):
    with app.app_context():
        team, active_user = _make_team_and_user(email="active@example.com", username="active", is_active=True)
        _, inactive_user = _make_team_and_user(email="inactive@example.com", username="inactive", is_active=False)
        _make_task(team, active_user)

        with caplog.at_level(logging.INFO):
            result = send_daily_digest()

        assert result == "Digest sent to 1 users"
        assert f"user_id={inactive_user.id}" not in caplog.text


def test_send_daily_digest_counts_only_non_done_tasks_per_user(app, caplog):
    """Plant-confirmed: flipping the status filter's != to == turns this
    assertion red even though 'digest sent to N users' alone would not."""
    with app.app_context():
        team, user = _make_team_and_user()
        project = Project(name="Proj", team_id=team.id)
        db.session.add(project)
        db.session.commit()
        statuses = ["todo", "in_progress", "done"]
        for status in statuses:
            db.session.add(
                Task(title=status, status=status, project_id=project.id, creator_id=user.id, assignee_id=user.id)
            )
        db.session.commit()

        with caplog.at_level(logging.INFO):
            send_daily_digest()

        digest_lines = [r.message for r in caplog.records if f"user_id={user.id}" in r.message]
        assert len(digest_lines) == 1
        assert "2 pending tasks" in digest_lines[0]


def test_send_daily_digest_zero_users_returns_zero_count(app):
    with app.app_context():
        assert send_daily_digest() == "Digest sent to 0 users"
