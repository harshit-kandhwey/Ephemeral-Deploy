import pytest
from src.models.project import Project
from src.models.user import User
from src.extensions import db


@pytest.fixture
def project_id(client, auth_headers):
    """auth_headers already created the team — create a project in that team"""
    with client.application.app_context():
        user = User.query.filter_by(username="testuser").first()
        project = Project(name="Test Project", team_id=user.team_id)
        db.session.add(project)
        db.session.commit()
        return project.id


@pytest.fixture
def task_id(client, auth_headers, project_id):
    """Create a task and return its ID"""
    response = client.post(
        "/api/v1/tasks",
        headers=auth_headers,
        json={
            "title": "Existing Task",
            "description": "Already exists",
            "priority": "medium",
            "project_id": project_id,
        },
    )
    assert response.status_code == 201, response.json
    return response.json["id"]


# --- CREATE ---


def test_create_task(client, auth_headers, project_id):
    response = client.post(
        "/api/v1/tasks",
        headers=auth_headers,
        json={
            "title": "Test Task",
            "description": "This is a test task",
            "priority": "high",
            "project_id": project_id,
        },
    )
    assert response.status_code == 201
    assert response.json["title"] == "Test Task"
    assert response.json["priority"] == "high"
    assert response.json["status"] == "todo"


def test_create_task_missing_fields(client, auth_headers):
    response = client.post(
        "/api/v1/tasks", headers=auth_headers, json={"title": "No Project"}
    )
    assert response.status_code == 400


def test_create_task_unauthenticated(client, project_id):
    response = client.post(
        "/api/v1/tasks", json={"title": "Test Task", "project_id": project_id}
    )
    assert response.status_code == 401


# --- READ ---


def test_get_tasks(client, auth_headers):
    response = client.get("/api/v1/tasks", headers=auth_headers)
    assert response.status_code == 200
    assert "tasks" in response.json
    assert "total" in response.json
    assert "pages" in response.json
    assert "current_page" in response.json


def test_get_tasks_filter_by_status(client, auth_headers, task_id):
    response = client.get("/api/v1/tasks?status=todo", headers=auth_headers)
    assert response.status_code == 200
    for task in response.json["tasks"]:
        assert task["status"] == "todo"


def test_get_tasks_filter_by_priority(client, auth_headers, task_id):
    response = client.get("/api/v1/tasks?priority=medium", headers=auth_headers)
    assert response.status_code == 200
    for task in response.json["tasks"]:
        assert task["priority"] == "medium"


def test_get_tasks_pagination(client, auth_headers, project_id):
    for i in range(3):
        client.post(
            "/api/v1/tasks",
            headers=auth_headers,
            json={"title": f"Task {i}", "project_id": project_id},
        )

    response = client.get("/api/v1/tasks?page=1&per_page=2", headers=auth_headers)
    assert response.status_code == 200
    assert len(response.json["tasks"]) <= 2
    assert response.json["total"] >= 3


def test_get_single_task(client, auth_headers, task_id):
    response = client.get(f"/api/v1/tasks/{task_id}", headers=auth_headers)
    assert response.status_code == 200
    assert response.json["id"] == task_id
    assert "comments" in response.json


def test_get_nonexistent_task(client, auth_headers):
    response = client.get("/api/v1/tasks/99999", headers=auth_headers)
    assert response.status_code == 404


# --- UPDATE ---


def test_update_task_title(client, auth_headers, task_id):
    response = client.put(
        f"/api/v1/tasks/{task_id}",
        headers=auth_headers,
        json={"title": "Updated Title"},
    )
    assert response.status_code == 200
    assert response.json["title"] == "Updated Title"


def test_update_task_status(client, auth_headers, task_id):
    response = client.put(
        f"/api/v1/tasks/{task_id}", headers=auth_headers, json={"status": "in_progress"}
    )
    assert response.status_code == 200
    assert response.json["status"] == "in_progress"


def test_update_task_status_to_done_sets_completed_at(client, auth_headers, task_id):
    response = client.put(
        f"/api/v1/tasks/{task_id}", headers=auth_headers, json={"status": "done"}
    )
    assert response.status_code == 200
    assert response.json["status"] == "done"
    assert response.json["completed_at"] is not None


def test_update_task_priority(client, auth_headers, task_id):
    response = client.put(
        f"/api/v1/tasks/{task_id}", headers=auth_headers, json={"priority": "critical"}
    )
    assert response.status_code == 200
    assert response.json["priority"] == "critical"


# --- DELETE ---


def test_delete_task_as_developer_forbidden(client, auth_headers, task_id):
    response = client.delete(f"/api/v1/tasks/{task_id}", headers=auth_headers)
    assert response.status_code == 403


def test_delete_task_as_admin(client, admin_headers, auth_headers, task_id):
    response = client.delete(f"/api/v1/tasks/{task_id}", headers=admin_headers)
    assert response.status_code == 200

    get = client.get(f"/api/v1/tasks/{task_id}", headers=admin_headers)
    assert get.status_code == 404
