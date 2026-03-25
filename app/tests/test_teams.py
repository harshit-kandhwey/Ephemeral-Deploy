from src.models.team import Team


# admin_headers and manager_headers fixtures are defined in conftest.py

# --- READ ---

def test_get_teams(client, auth_headers):
    response = client.get('/api/v1/teams', headers=auth_headers)
    assert response.status_code == 200
    assert 'teams' in response.json
    assert 'count' in response.json


def test_get_single_team(client, auth_headers):
    with client.application.app_context():
        team_id = Team.query.first().id

    response = client.get(f'/api/v1/teams/{team_id}', headers=auth_headers)
    assert response.status_code == 200
    assert response.json['id'] == team_id


def test_get_nonexistent_team(client, auth_headers):
    response = client.get('/api/v1/teams/99999', headers=auth_headers)
    assert response.status_code == 404


# --- CREATE ---

def test_create_team_as_admin(client, admin_headers):
    response = client.post('/api/v1/teams', headers=admin_headers, json={
        'name': 'New Team',
        'description': 'A new team'
    })
    assert response.status_code == 201
    assert response.json['name'] == 'New Team'


def test_create_team_as_developer_forbidden(client, auth_headers):
    response = client.post('/api/v1/teams', headers=auth_headers, json={
        'name': 'Unauthorized Team'
    })
    assert response.status_code == 403


def test_create_team_missing_name(client, admin_headers):
    response = client.post('/api/v1/teams', headers=admin_headers, json={
        'description': 'No name given'
    })
    assert response.status_code == 400


def test_create_duplicate_team_name(client, admin_headers):
    # Create the initial team and verify success
    response1 = client.post('/api/v1/teams', headers=admin_headers,
                            json={'name': 'Duplicate'})
    assert response1.status_code == 201
    assert response1.json['name'] == 'Duplicate'

    # Attempt to create a duplicate and verify it fails with 409 Conflict
    response2 = client.post(
        '/api/v1/teams', headers=admin_headers, json={'name': 'Duplicate'})
    assert response2.status_code == 409


# --- UPDATE ---

def test_update_team_as_admin(client, admin_headers):
    with client.application.app_context():
        first_team = Team.query.first()
        assert first_team is not None, "No teams exist in database"
        team_id = first_team.id

    response = client.put(f'/api/v1/teams/{team_id}', headers=admin_headers, json={
        'description': 'Updated description'
    })
    assert response.status_code == 200
    assert response.json['description'] == 'Updated description'


def test_update_team_as_developer_forbidden(client, auth_headers):
    with client.application.app_context():
        first_team = Team.query.first()
        assert first_team is not None, "No teams exist in database"
        team_id = first_team.id

    response = client.put(f'/api/v1/teams/{team_id}', headers=auth_headers, json={
        'name': 'Hacked'
    })
    assert response.status_code == 403