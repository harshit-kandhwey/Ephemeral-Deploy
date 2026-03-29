import pytest
from src.models.team import Team


@pytest.fixture
def team_id(client, auth_headers):
    """auth_headers already created the team — just return its id"""
    with client.application.app_context():
        return Team.query.first().id


@pytest.fixture
def project_id(client, manager_headers, team_id):
    response = client.post(
        "/api/v1/projects",
        headers=manager_headers,
        json={
            "name": "Test Project",
            "description": "A project for testing",
            "team_id": team_id,
        },
    )
    assert response.status_code == 201, response.json
    return response.json["id"]


# --- CREATE ---


def test_create_project_as_manager(client, manager_headers, team_id):
    response = client.post(
        "/api/v1/projects",
        headers=manager_headers,
        json={"name": "New Project", "description": "Description", "team_id": team_id},
    )
    assert response.status_code == 201
    assert response.json["name"] == "New Project"


def test_create_project_as_developer_forbidden(client, auth_headers, team_id):
    response = client.post(
        "/api/v1/projects",
        headers=auth_headers,
        json={"name": "Unauthorized Project", "team_id": team_id},
    )
    assert response.status_code == 403


def test_create_project_missing_fields(client, manager_headers):
    response = client.post(
        "/api/v1/projects", headers=manager_headers, json={"name": "No Team"}
    )
    assert response.status_code == 400


# --- READ ---


def test_get_projects(client, auth_headers, project_id):
    response = client.get("/api/v1/projects", headers=auth_headers)
    assert response.status_code == 200
    assert "projects" in response.json
    assert "count" in response.json


def test_get_single_project(client, auth_headers, project_id):
    response = client.get(f"/api/v1/projects/{project_id}", headers=auth_headers)
    assert response.status_code == 200
    assert response.json["id"] == project_id


def test_get_nonexistent_project(client, auth_headers):
    response = client.get("/api/v1/projects/99999", headers=auth_headers)
    assert response.status_code == 404


# --- UPDATE ---


def test_update_project_name(client, manager_headers, project_id):
    response = client.put(
        f"/api/v1/projects/{project_id}",
        headers=manager_headers,
        json={"name": "Renamed Project"},
    )
    assert response.status_code == 200
    assert response.json["name"] == "Renamed Project"


def test_update_project_status(client, manager_headers, project_id):
    response = client.put(
        f"/api/v1/projects/{project_id}",
        headers=manager_headers,
        json={"status": "archived"},
    )
    assert response.status_code == 200
    assert response.json["status"] == "archived"


def test_update_project_as_developer_forbidden(client, auth_headers, project_id):
    response = client.put(
        f"/api/v1/projects/{project_id}", headers=auth_headers, json={"name": "Hacked"}
    )
    assert response.status_code == 403
