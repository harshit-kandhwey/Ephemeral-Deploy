"""
Tests for /api/v1/users endpoints.
Coverage target: users.py lines 26-27, 42-50, 57-112, 120-123
"""
import pytest
from src.models.user import User
from src.extensions import db


# ── fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def admin_user_id(client, admin_headers):
    """Return the ID of the admin user who owns admin_headers."""
    r = client.get('/api/v1/auth/me', headers=admin_headers)
    assert r.status_code == 200
    return r.json['id']


@pytest.fixture
def dev_user_id(client, auth_headers):
    """Return the ID of the developer user who owns auth_headers."""
    r = client.get('/api/v1/auth/me', headers=auth_headers)
    assert r.status_code == 200
    return r.json['id']


# ── GET /users ─────────────────────────────────────────────────────────────────

def test_get_users_as_admin(client, admin_headers):
    r = client.get('/api/v1/users', headers=admin_headers)
    assert r.status_code == 200
    assert 'users' in r.json
    assert 'count' in r.json
    assert r.json['count'] >= 1


def test_get_users_as_developer_forbidden(client, auth_headers):
    r = client.get('/api/v1/users', headers=auth_headers)
    assert r.status_code == 403


def test_get_users_unauthenticated(client):
    r = client.get('/api/v1/users')
    assert r.status_code == 401


# ── GET /users/<id> ────────────────────────────────────────────────────────────

def test_get_user_self(client, auth_headers, dev_user_id):
    """A developer can fetch their own profile."""
    r = client.get(f'/api/v1/users/{dev_user_id}', headers=auth_headers)
    assert r.status_code == 200
    assert r.json['id'] == dev_user_id
    # email included when fetching own profile
    assert 'email' in r.json


def test_get_user_as_admin_includes_email(client, admin_headers, dev_user_id):
    """Admin fetching another user's profile gets email."""
    r = client.get(f'/api/v1/users/{dev_user_id}', headers=admin_headers)
    assert r.status_code == 200
    assert 'email' in r.json


def test_get_user_nonexistent(client, auth_headers):
    r = client.get('/api/v1/users/99999', headers=auth_headers)
    assert r.status_code == 404


def test_get_user_unauthenticated(client, dev_user_id):
    r = client.get(f'/api/v1/users/{dev_user_id}')
    assert r.status_code == 401


# ── PUT /users/<id> ────────────────────────────────────────────────────────────

def test_update_own_full_name(client, auth_headers, dev_user_id):
    r = client.put(f'/api/v1/users/{dev_user_id}', headers=auth_headers,
                   json={'full_name': 'Updated Name'})
    assert r.status_code == 200
    assert r.json['full_name'] == 'Updated Name'


def test_update_own_password(client, auth_headers, dev_user_id):
    r = client.put(f'/api/v1/users/{dev_user_id}', headers=auth_headers,
                   json={'password': 'NewPassword123!'})
    assert r.status_code == 200


def test_update_other_user_as_developer_forbidden(client, auth_headers, admin_user_id):
    """Developer cannot update another user's profile."""
    r = client.put(f'/api/v1/users/{admin_user_id}', headers=auth_headers,
                   json={'full_name': 'Hacked'})
    assert r.status_code == 403


def test_update_user_no_data(client, auth_headers, dev_user_id):
    r = client.put(f'/api/v1/users/{dev_user_id}', headers=auth_headers,
                   json=None, content_type='application/json')
    assert r.status_code == 400


def test_admin_can_update_role(client, admin_headers, dev_user_id):
    r = client.put(f'/api/v1/users/{dev_user_id}', headers=admin_headers,
                   json={'role': 'manager'})
    assert r.status_code == 200
    assert r.json['role'] == 'manager'


def test_admin_update_invalid_role(client, admin_headers, dev_user_id):
    r = client.put(f'/api/v1/users/{dev_user_id}', headers=admin_headers,
                   json={'role': 'superuser'})
    assert r.status_code == 400


def test_admin_can_deactivate_user(client, admin_headers, dev_user_id):
    r = client.put(f'/api/v1/users/{dev_user_id}', headers=admin_headers,
                   json={'is_active': False})
    assert r.status_code == 200
    assert r.json['is_active'] is False


def test_admin_update_is_active_invalid_type(client, admin_headers, dev_user_id):
    r = client.put(f'/api/v1/users/{dev_user_id}', headers=admin_headers,
                   json={'is_active': 'yes'})
    assert r.status_code == 400


def test_admin_can_assign_team(client, admin_headers, dev_user_id):
    """Admin can set team_id to None (remove from team)."""
    r = client.put(f'/api/v1/users/{dev_user_id}', headers=admin_headers,
                   json={'team_id': None})
    assert r.status_code == 200


def test_admin_assign_nonexistent_team(client, admin_headers, dev_user_id):
    r = client.put(f'/api/v1/users/{dev_user_id}', headers=admin_headers,
                   json={'team_id': 99999})
    assert r.status_code == 400


# ── DELETE /users/<id> ─────────────────────────────────────────────────────────

def test_delete_user_as_admin(client, admin_headers, dev_user_id):
    """Soft-delete: sets is_active=False, user still exists."""
    r = client.delete(f'/api/v1/users/{dev_user_id}', headers=admin_headers)
    assert r.status_code == 200

    # Verify user is deactivated, not removed
    with client.application.app_context():
        user = db.session.get(User, dev_user_id)
        assert user is not None
        assert user.is_active is False


def test_delete_user_as_developer_forbidden(client, auth_headers, dev_user_id):
    r = client.delete(f'/api/v1/users/{dev_user_id}', headers=auth_headers)
    assert r.status_code == 403


def test_delete_nonexistent_user(client, admin_headers):
    r = client.delete('/api/v1/users/99999', headers=admin_headers)
    assert r.status_code == 404