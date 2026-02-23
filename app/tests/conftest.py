from app.src.models.team import Team
from app.src.models.user import User
from app.src.extensions import db
from app.src import create_app
import pytest
import sys
import os

# Add src directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))


@pytest.fixture
def app():
    """Create and configure test app"""
    app = create_app('testing')

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
    """Get JWT token for testing"""
    # Create test user
    with client.application.app_context():
        team = Team(name='Test Team')
        db.session.add(team)
        db.session.commit()

        user = User(
            email='test@test.com',
            username='testuser',
            full_name='Test User',
            team_id=team.id
        )
        user.set_password('password123')
        db.session.add(user)
        db.session.commit()

    # Login
    response = client.post('/api/v1/auth/login', json={
        'username': 'testuser',
        'password': 'password123'
    })

    token = response.json['access_token']
    return {'Authorization': f'Bearer {token}'}
