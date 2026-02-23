"""
Initialize database with sample data
Run this script to populate the database with test data
"""
import sys
import os
from app.src.models.task import Task
from app.src.models.project import Project
from app.src.models.team import Team
from app.src.models.user import User
from app.src.extensions import db
from app.src import create_app

# Add parent directory to path so we can import our modules
sys.path.insert(0, os.path.dirname(__file__))


def init_database():
    app = create_app('development')

    with app.app_context():
        # Drop and recreate all tables
        print("Dropping existing tables...")
        db.drop_all()

        print("Creating tables...")
        db.create_all()

        print("Creating sample data...")

        # Create teams
        team1 = Team(name='Engineering',
                     description='Backend and frontend developers')
        team2 = Team(name='Product',
                     description='Product managers and designers')

        db.session.add_all([team1, team2])
        db.session.commit()

        # Create users
        admin = User(
            email='admin@nexusdeploy.com',
            username='admin',
            full_name='Admin User',
            role='admin',
            team_id=team1.id
        )
        admin.set_password('admin123')

        manager = User(
            email='manager@nexusdeploy.com',
            username='manager',
            full_name='Manager User',
            role='manager',
            team_id=team1.id
        )
        manager.set_password('manager123')

        dev1 = User(
            email='dev1@nexusdeploy.com',
            username='developer1',
            full_name='Developer One',
            role='developer',
            team_id=team1.id
        )
        dev1.set_password('dev123')

        dev2 = User(
            email='dev2@nexusdeploy.com',
            username='developer2',
            full_name='Developer Two',
            role='developer',
            team_id=team1.id
        )
        dev2.set_password('dev123')

        db.session.add_all([admin, manager, dev1, dev2])
        db.session.commit()

        # Create projects
        project1 = Project(
            name='NexusDeploy Platform',
            description='CI/CD automation platform',
            team_id=team1.id
        )

        project2 = Project(
            name='Mobile App',
            description='iOS and Android applications',
            team_id=team1.id
        )

        db.session.add_all([project1, project2])
        db.session.commit()

        # Create tasks
        task1 = Task(
            title='Implement authentication system',
            description='Build JWT-based authentication with refresh tokens',
            priority='high',
            status='in_progress',
            project_id=project1.id,
            creator_id=manager.id,
            assignee_id=dev1.id
        )

        task2 = Task(
            title='Set up CI/CD pipeline',
            description='Configure GitHub Actions for automated testing and deployment',
            priority='critical',
            status='todo',
            project_id=project1.id,
            creator_id=manager.id,
            assignee_id=dev2.id
        )

        task3 = Task(
            title='Design user dashboard',
            description='Create mockups for the main user dashboard',
            priority='medium',
            status='done',
            project_id=project2.id,
            creator_id=manager.id,
            assignee_id=dev1.id
        )

        db.session.add_all([task1, task2, task3])
        db.session.commit()

        print("\n" + "="*60)
        print("✓ Database initialized successfully!")
        print("="*60)
        print("\nSample users created:")
        print("  Admin:     admin / admin123")
        print("  Manager:   manager / manager123")
        print("  Developer: developer1 / dev123")
        print("  Developer: developer2 / dev123")
        print("\nYou can now login at: http://localhost:5000/api/v1/auth/login")
        print("="*60 + "\n")


if __name__ == '__main__':
    init_database()
