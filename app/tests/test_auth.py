import sys
import os

# Add src directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))


def test_register(client):
    response = client.post('/api/v1/auth/register', json={
        'email': 'new@test.com',
        'username': 'newuser',
        'password': 'password123',
        'full_name': 'New User'
    })

    assert response.status_code == 201
    assert response.json['user']['username'] == 'newuser'


def test_login_success(client, auth_headers):
    response = client.post('/api/v1/auth/login', json={
        'username': 'testuser',
        'password': 'password123'
    })

    assert response.status_code == 200
    assert 'access_token' in response.json
    assert 'refresh_token' in response.json


def test_login_invalid_credentials(client):
    response = client.post('/api/v1/auth/login', json={
        'username': 'testuser',
        'password': 'wrongpassword'
    })

    assert response.status_code == 401


def test_get_current_user(client, auth_headers):
    response = client.get('/api/v1/auth/me', headers=auth_headers)

    assert response.status_code == 200
    assert response.json['username'] == 'testuser'


def test_access_without_token(client):
    response = client.get('/api/v1/tasks')

    assert response.status_code == 401
