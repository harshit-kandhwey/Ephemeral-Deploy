from src.extensions import db
from src.models.user import User


def test_register(client):
    response = client.post(
        "/api/v1/auth/register",
        json={
            "email": "new@test.com",
            "username": "newuser",
            "password": "password123",
            "full_name": "New User",
        },
    )
    assert response.status_code == 201
    assert response.json["user"]["username"] == "newuser"


def test_register_duplicate_email(client, auth_headers):
    response = client.post(
        "/api/v1/auth/register",
        json={
            "email": "test@test.com",
            "username": "anotheruser",
            "password": "password123",
        },
    )
    assert response.status_code == 400
    assert "Email already registered" in response.json["error"]


def test_register_duplicate_username(client, auth_headers):
    response = client.post(
        "/api/v1/auth/register",
        json={
            "email": "other@test.com",
            "username": "testuser",
            "password": "password123",
        },
    )
    assert response.status_code == 400
    assert "Username already taken" in response.json["error"]


def test_register_missing_fields(client):
    response = client.post("/api/v1/auth/register", json={"email": "new@test.com"})
    assert response.status_code == 400


def test_login_success(client, auth_headers):
    response = client.post("/api/v1/auth/login", json={"username": "testuser", "password": "password123"})
    assert response.status_code == 200
    assert "access_token" in response.json
    assert "refresh_token" in response.json


def test_login_invalid_credentials(client):
    response = client.post("/api/v1/auth/login", json={"username": "testuser", "password": "wrongpassword"})
    assert response.status_code == 401


def test_login_nonexistent_user(client):
    response = client.post("/api/v1/auth/login", json={"username": "nobody", "password": "password123"})
    assert response.status_code == 401


def test_login_missing_fields(client):
    response = client.post("/api/v1/auth/login", json={"username": "testuser"})
    assert response.status_code == 400


def test_get_current_user(client, auth_headers):
    response = client.get("/api/v1/auth/me", headers=auth_headers)
    assert response.status_code == 200
    assert response.json["username"] == "testuser"


def test_access_without_token(client):
    response = client.get("/api/v1/tasks")
    assert response.status_code == 401


def test_refresh_token(client, auth_headers):
    # Get refresh token from login
    login = client.post("/api/v1/auth/login", json={"username": "testuser", "password": "password123"})
    refresh_token = login.json["refresh_token"]

    response = client.post("/api/v1/auth/refresh", headers={"Authorization": f"Bearer {refresh_token}"})
    assert response.status_code == 200
    assert "access_token" in response.json


def test_access_token_cannot_refresh(client, auth_headers):
    # Access token should not work on the refresh endpoint
    response = client.post("/api/v1/auth/refresh", headers=auth_headers)
    assert response.status_code == 422


def test_me_rejects_disabled_account(client, auth_headers):
    # A token minted while active must stop working once the account is disabled.
    with client.application.app_context():
        user = User.query.filter_by(username="testuser").first()
        user.is_active = False
        db.session.commit()

    response = client.get("/api/v1/auth/me", headers=auth_headers)
    assert response.status_code == 403


def test_logout_revokes_refresh_token(client):
    # auth_headers is not reused here — we need the raw refresh token from login.
    with client.application.app_context():
        user = User(email="lo@test.com", username="logoutuser", full_name="Logout User")
        user.set_password("password123")
        db.session.add(user)
        db.session.commit()

    login = client.post("/api/v1/auth/login", json={"username": "logoutuser", "password": "password123"})
    access = login.json["access_token"]
    refresh = login.json["refresh_token"]

    # Refresh works before logout.
    pre = client.post("/api/v1/auth/refresh", headers={"Authorization": f"Bearer {refresh}"})
    assert pre.status_code == 200

    # Logout with the refresh token in the body revokes both tokens.
    out = client.post(
        "/api/v1/auth/logout",
        headers={"Authorization": f"Bearer {access}"},
        json={"refresh_token": refresh},
    )
    assert out.status_code == 200

    # The refresh token can no longer mint access tokens.
    post = client.post("/api/v1/auth/refresh", headers={"Authorization": f"Bearer {refresh}"})
    assert post.status_code == 401


def test_logout_rejects_foreign_refresh_token(client, auth_headers):
    # A caller cannot revoke someone else's refresh token by passing it to logout.
    with client.application.app_context():
        other = User(email="victim@test.com", username="victim", full_name="Victim")
        other.set_password("password123")
        db.session.add(other)
        db.session.commit()

    victim_login = client.post("/api/v1/auth/login", json={"username": "victim", "password": "password123"})
    victim_refresh = victim_login.json["refresh_token"]

    out = client.post("/api/v1/auth/logout", headers=auth_headers, json={"refresh_token": victim_refresh})
    assert out.status_code == 400

    # The victim's refresh token still works.
    still = client.post("/api/v1/auth/refresh", headers={"Authorization": f"Bearer {victim_refresh}"})
    assert still.status_code == 200
