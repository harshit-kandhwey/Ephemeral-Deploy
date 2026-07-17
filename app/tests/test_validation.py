"""
Input-validation tests.

Every case here previously produced a 500: the bad value reached SQLAlchemy or
Postgres and the database raised, instead of the API rejecting the request. The
assertions are deliberately "not 500" plus "is 400" — the point is that invalid
input is a client error, not a server crash.
"""

import pytest

from src.extensions import db
from src.models.project import Project
from src.models.task import Task


@pytest.fixture
def task_id(client, auth_headers):
    """A task owned by the test user's team."""
    with client.application.app_context():
        project = Project(name="Validation Project", team_id=1)
        db.session.add(project)
        db.session.commit()

        task = Task(title="Existing task", project_id=project.id, creator_id=1)
        db.session.add(task)
        db.session.commit()
        return task.id


# ── Null / malformed body ──────────────────────────────────────────────────
# `"title" in None` raises TypeError, which escapes the handler as a 500.


def test_update_task_null_body(client, auth_headers, task_id):
    response = client.put(f"/api/v1/tasks/{task_id}", json=None, headers=auth_headers)
    assert response.status_code == 400
    assert "error" in response.json


def test_update_task_list_body(client, auth_headers, task_id):
    response = client.put(f"/api/v1/tasks/{task_id}", json=["not", "an", "object"], headers=auth_headers)
    assert response.status_code == 400


def test_create_task_null_body(client, auth_headers):
    response = client.post("/api/v1/tasks", json=None, headers=auth_headers)
    assert response.status_code == 400


# ── due_date parsing ───────────────────────────────────────────────────────
# datetime.fromisoformat raises ValueError on garbage input.


def test_create_task_invalid_due_date(client, auth_headers, task_id):
    response = client.post(
        "/api/v1/tasks",
        json={"title": "T", "project_id": 1, "due_date": "not-a-date"},
        headers=auth_headers,
    )
    assert response.status_code == 400
    assert "due_date" in response.json["error"]


def test_create_task_valid_due_date(client, auth_headers, task_id):
    response = client.post(
        "/api/v1/tasks",
        json={"title": "T", "project_id": 1, "due_date": "2026-12-31T14:30:00"},
        headers=auth_headers,
    )
    assert response.status_code == 201
    assert response.json["due_date"].startswith("2026-12-31")


# ── Non-numeric query filters ──────────────────────────────────────────────
# A string in an integer column is a Postgres DataError.


@pytest.mark.parametrize("param", ["project_id", "assignee_id"])
def test_list_tasks_non_numeric_filter(client, auth_headers, param):
    response = client.get(f"/api/v1/tasks?{param}=abc", headers=auth_headers)
    assert response.status_code == 400
    assert param in response.json["error"]


# ── Foreign keys that do not exist ─────────────────────────────────────────
# An unknown id reaches the DB as an IntegrityError (FK violation).


def test_create_task_nonexistent_project(client, auth_headers):
    response = client.post(
        "/api/v1/tasks",
        json={"title": "T", "project_id": 99999},
        headers=auth_headers,
    )
    assert response.status_code == 400
    assert "project_id" in response.json["error"]


def test_create_task_nonexistent_assignee(client, auth_headers, task_id):
    response = client.post(
        "/api/v1/tasks",
        json={"title": "T", "project_id": 1, "assignee_id": 99999},
        headers=auth_headers,
    )
    assert response.status_code == 400
    assert "assignee_id" in response.json["error"]


def test_create_project_nonexistent_team(client, manager_headers):
    response = client.post(
        "/api/v1/projects",
        json={"name": "P", "team_id": 99999},
        headers=manager_headers,
    )
    assert response.status_code == 400
    assert "team_id" in response.json["error"]


# ── Enum validation ────────────────────────────────────────────────────────
# The columns are plain strings and would store anything at all.


def test_create_task_invalid_priority(client, auth_headers, task_id):
    response = client.post(
        "/api/v1/tasks",
        json={"title": "T", "project_id": 1, "priority": "URGENT!!!"},
        headers=auth_headers,
    )
    assert response.status_code == 400
    assert "priority" in response.json["error"]


def test_update_task_invalid_status(client, auth_headers, task_id):
    response = client.put(
        f"/api/v1/tasks/{task_id}",
        json={"status": "almost_done"},
        headers=auth_headers,
    )
    assert response.status_code == 400
    assert "status" in response.json["error"]


def test_update_task_valid_status(client, auth_headers, task_id):
    response = client.put(f"/api/v1/tasks/{task_id}", json={"status": "done"}, headers=auth_headers)
    assert response.status_code == 200
    assert response.json["status"] == "done"
    assert response.json["completed_at"] is not None


def test_invalid_status_does_not_partially_update(client, auth_headers, task_id):
    """Validation runs before any mutation — a bad field must not leave a half-applied change."""
    response = client.put(
        f"/api/v1/tasks/{task_id}",
        json={"title": "Renamed", "status": "bogus"},
        headers=auth_headers,
    )
    assert response.status_code == 400

    check = client.get(f"/api/v1/tasks/{task_id}", headers=auth_headers)
    assert check.json["title"] == "Existing task", "title was changed despite the request being rejected"


# ── Password policy ────────────────────────────────────────────────────────


def test_register_short_password_rejected(client):
    response = client.post(
        "/api/v1/auth/register",
        json={"email": "a@b.com", "username": "shortpw", "password": "x"},
    )
    assert response.status_code == 400
    assert "Password" in response.json["error"]


def test_register_overlong_password_rejected(client):
    """bcrypt silently truncates past 72 bytes — accepting a longer password would be dishonest."""
    response = client.post(
        "/api/v1/auth/register",
        json={"email": "a@b.com", "username": "longpw", "password": "a" * 100},
    )
    assert response.status_code == 400
    assert "72" in response.json["error"]


def test_register_valid_password_accepted(client):
    response = client.post(
        "/api/v1/auth/register",
        json={"email": "ok@b.com", "username": "okpw", "password": "goodpassword123"},
    )
    assert response.status_code == 201


def test_password_update_enforces_policy(client, auth_headers):
    """The policy must hold on the update path too, or it is trivially bypassed."""
    response = client.put("/api/v1/users/1", json={"password": "short"}, headers=auth_headers)
    assert response.status_code == 400
    assert "Password" in response.json["error"]


# ── Failed-login auditing ──────────────────────────────────────────────────


def test_failed_login_is_audited(client, auth_headers):
    """An audit trail recording only successes cannot evidence a brute-force attempt."""
    from src.models.audit_log import AuditLog

    client.post("/api/v1/auth/login", json={"username": "testuser", "password": "wrongpassword"})

    with client.application.app_context():
        failures = AuditLog.query.filter_by(action="login_failed").all()
        assert len(failures) == 1
        assert failures[0].changes["username"] == "testuser"


def test_failed_login_unknown_user_is_audited(client):
    """entity_id is NOT NULL, so an unknown username must not blow up the audit write."""
    from src.models.audit_log import AuditLog

    response = client.post("/api/v1/auth/login", json={"username": "ghost", "password": "whatever"})
    assert response.status_code == 401

    with client.application.app_context():
        failures = AuditLog.query.filter_by(action="login_failed").all()
        assert len(failures) == 1
        assert failures[0].user_id is None
        assert failures[0].changes["username"] == "ghost"
