from src import create_app
from src.extensions import db
from src.models.user import User
from src.models.team import Team
import pytest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


@pytest.fixture
def app():
    """Create and configure test app"""
    app = create_app("testing")

    with app.app_context():
        db.create_all()
        yield app
        db.session.remove()
        db.drop_all()


@pytest.fixture
def client(app):
    """Create test client"""
    return app.test_client()


@pytest.fixture
def auth_headers(client):
    """Create a developer user and return auth headers"""
    with client.application.app_context():
        team = Team(name="Test Team")
        db.session.add(team)
        db.session.commit()

        user = User(
            email="test@test.com",
            username="testuser",
            full_name="Test User",
            team_id=team.id,
        )
        user.set_password("password123")
        db.session.add(user)
        db.session.commit()

    response = client.post(
        "/api/v1/auth/login", json={"username": "testuser", "password": "password123"}
    )
    token = response.json["access_token"]
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def admin_headers(client, auth_headers):
    """Create an admin user and return auth headers.
    Depends on auth_headers so the team already exists in the DB."""
    with client.application.app_context():
        team = Team.query.first()
        admin = User(
            email="admin@test.com",
            username="adminuser",
            full_name="Admin",
            role="admin",
            team_id=team.id,
        )
        admin.set_password("admin123")
        db.session.add(admin)
        db.session.commit()

    login = client.post(
        "/api/v1/auth/login", json={"username": "adminuser", "password": "admin123"}
    )
    return {"Authorization": f'Bearer {login.json["access_token"]}'}


@pytest.fixture
def manager_headers(client, auth_headers):
    """Create a manager user and return auth headers.
    Depends on auth_headers so the team already exists in the DB."""
    with client.application.app_context():
        team = Team.query.first()
        manager = User(
            email="manager@test.com",
            username="manageruser",
            full_name="Manager",
            role="manager",
            team_id=team.id,
        )
        manager.set_password("manager123")
        db.session.add(manager)
        db.session.commit()

    login = client.post(
        "/api/v1/auth/login", json={"username": "manageruser", "password": "manager123"}
    )
    return {"Authorization": f'Bearer {login.json["access_token"]}'}
