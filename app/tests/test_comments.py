import pytest

from src.extensions import db
from src.models.project import Project
from src.models.user import User


@pytest.fixture
def task_id(client, auth_headers):
    """Create a project and task, return task ID"""
    with client.application.app_context():
        user = User.query.filter_by(username="testuser").first()
        project = Project(name="Comment Test Project", team_id=user.team_id)
        db.session.add(project)
        db.session.commit()
        project_id = project.id

    response = client.post(
        "/api/v1/tasks",
        headers=auth_headers,
        json={"title": "Task for Comments", "project_id": project_id},
    )
    assert response.status_code == 201, response.json
    return response.json["id"]


def test_create_comment(client, auth_headers, task_id):
    response = client.post(
        f"/api/v1/tasks/{task_id}/comments",
        headers=auth_headers,
        json={"content": "This is a comment"},
    )
    assert response.status_code == 201
    assert response.json["content"] == "This is a comment"


def test_create_comment_missing_content(client, auth_headers, task_id):
    response = client.post(f"/api/v1/tasks/{task_id}/comments", headers=auth_headers, json={})
    assert response.status_code == 400


def test_create_comment_on_nonexistent_task(client, auth_headers):
    response = client.post(
        "/api/v1/tasks/99999/comments",
        headers=auth_headers,
        json={"content": "Ghost comment"},
    )
    assert response.status_code == 404


def test_get_comments(client, auth_headers, task_id):
    client.post(
        f"/api/v1/tasks/{task_id}/comments",
        headers=auth_headers,
        json={"content": "First comment"},
    )

    response = client.get(f"/api/v1/tasks/{task_id}/comments", headers=auth_headers)
    assert response.status_code == 200
    assert "comments" in response.json
    assert "count" in response.json
    assert response.json["count"] == 1
    assert response.json["comments"][0]["content"] == "First comment"


def test_get_comments_unauthenticated(client, task_id):
    response = client.get(f"/api/v1/tasks/{task_id}/comments")
    assert response.status_code == 401
