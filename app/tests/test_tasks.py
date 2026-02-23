from app.src.models.project import Project
from app.src.extensions import db


def test_create_task(client, auth_headers):
    # Create project first
    with client.application.app_context():
        from models.user import User
        user = User.query.filter_by(username='testuser').first()
        project = Project(name='Test Project', team_id=user.team_id)
        db.session.add(project)
        db.session.commit()
        project_id = project.id

    response = client.post('/api/v1/tasks',
                           headers=auth_headers,
                           json={
                               'title': 'Test Task',
                               'description': 'This is a test task',
                               'priority': 'high',
                               'project_id': project_id
                           }
                           )

    assert response.status_code == 201
    assert response.json['title'] == 'Test Task'
    assert response.json['priority'] == 'high'


def test_get_tasks(client, auth_headers):
    response = client.get('/api/v1/tasks', headers=auth_headers)

    assert response.status_code == 200
    assert 'tasks' in response.json
    assert 'total' in response.json
