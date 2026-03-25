def test_register(client):
    response = client.post('/api/v1/auth/register', json={
        'email': 'new@test.com',
        'username': 'newuser',
        'password': 'password123',
        'full_name': 'New User'
    })
    assert response.status_code == 201
    assert response.json['user']['username'] == 'newuser'


def test_register_duplicate_email(client, auth_headers):
    response = client.post('/api/v1/auth/register', json={
        'email': 'test@test.com',
        'username': 'anotheruser',
        'password': 'password123'
    })
    assert response.status_code == 400
    assert 'Email already registered' in response.json['error']


def test_register_duplicate_username(client, auth_headers):
    response = client.post('/api/v1/auth/register', json={
        'email': 'other@test.com',
        'username': 'testuser',
        'password': 'password123'
    })
    assert response.status_code == 400
    assert 'Username already taken' in response.json['error']


def test_register_missing_fields(client):
    response = client.post('/api/v1/auth/register', json={
        'email': 'new@test.com'
    })
    assert response.status_code == 400


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


def test_login_nonexistent_user(client):
    response = client.post('/api/v1/auth/login', json={
        'username': 'nobody',
        'password': 'password123'
    })
    assert response.status_code == 401


def test_login_missing_fields(client):
    response = client.post('/api/v1/auth/login', json={
        'username': 'testuser'
    })
    assert response.status_code == 400


def test_get_current_user(client, auth_headers):
    response = client.get('/api/v1/auth/me', headers=auth_headers)
    assert response.status_code == 200
    assert response.json['username'] == 'testuser'


def test_access_without_token(client):
    response = client.get('/api/v1/tasks')
    assert response.status_code == 401


def test_refresh_token(client, auth_headers):
    # Get refresh token from login
    login = client.post('/api/v1/auth/login', json={
        'username': 'testuser',
        'password': 'password123'
    })
    refresh_token = login.json['refresh_token']

    response = client.post('/api/v1/auth/refresh', headers={
        'Authorization': f'Bearer {refresh_token}'
    })
    assert response.status_code == 200
    assert 'access_token' in response.json


def test_access_token_cannot_refresh(client, auth_headers):
    # Access token should not work on the refresh endpoint
    response = client.post('/api/v1/auth/refresh', headers=auth_headers)
    assert response.status_code == 422