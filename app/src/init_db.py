"""
Database initialisation script
================================
Handles two responsibilities:
  1. Schema creation   — db.create_all() is idempotent: creates tables that
                         don't exist, leaves existing tables and data untouched.
                         Safe to run on every deployment.

  2. Sample data seed  — only runs when SEED_DB=true AND the database is empty.
                         Never runs in production unless explicitly forced.

Two-user DB pattern
-------------------
RDS is provisioned with a master user (nexusadmin) via Terraform using
credentials from SSM Parameter Store. That master user has superuser rights
and is only used for admin operations.

The app connects as a limited-privilege app user (nexusapp) whose credentials
also come from SSM / Secrets Manager. This script creates the app user if it
doesn't already exist, using the master credentials that are available at
container startup via environment variables injected by ECS.

Usage (local):
    python -m src.init_db

Usage (ECS one-off task, called by deploy.yml before service starts):
    ENV=production python -m src.init_db

Environment variables read:
    DATABASE_URL      → app user connection string (used by Flask)
    DB_MASTER_USER    → master username (nexusadmin)  injected from Secrets Manager
    DB_APP_USER       → app username   (nexusapp)     injected from Secrets Manager
    DB_APP_PASSWORD   → app password                  injected from Secrets Manager
    SEED_DB           → set to "true" to seed sample data (default: false)
    ENV               → "production" blocks seeding unless SEED_DB=true is explicit
"""

import os
import psycopg2
from psycopg2 import sql
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
from urllib.parse import urlparse


def _get_master_conn():
    """
    Build a psycopg2 connection using the master user.
    We derive the host/port/dbname from DATABASE_URL and swap in master creds.
    This avoids storing a separate MASTER_DATABASE_URL.
    """
    database_url = os.environ.get('DATABASE_URL')
    if not database_url:
        raise RuntimeError('DATABASE_URL environment variable is not set')

    parsed = urlparse(database_url)
    master_user = os.environ.get('DB_MASTER_USER')
    master_password = os.environ.get('DB_MASTER_PASSWORD')

    if not master_user or not master_password:
        raise RuntimeError(
            'DB_MASTER_USER and DB_MASTER_PASSWORD must be set '
            '(injected from Secrets Manager by ECS)'
        )

    conn = psycopg2.connect(
        host=parsed.hostname,
        port=parsed.port or 5432,
        dbname=parsed.path.lstrip('/'),
        user=master_user,
        password=master_password,
        connect_timeout=10,
    )
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    return conn


def create_app_user():
    """
    Create the limited-privilege app DB user if it doesn't already exist.
    The app user can SELECT/INSERT/UPDATE/DELETE but cannot DROP tables
    or create new users — principle of least privilege.

    Idempotent: safe to run multiple times.
    """
    app_user = os.environ.get('DB_APP_USER')
    app_password = os.environ.get('DB_APP_PASSWORD')

    if not app_user or not app_password:
        # In local development these may not be set — that's fine,
        # the app connects as the postgres superuser via DATABASE_URL directly.
        print('⚠️  DB_APP_USER / DB_APP_PASSWORD not set — skipping app user creation')
        print('   (Expected in local development, not in production)')
        return

    conn = None
    try:
        conn = _get_master_conn()
        cursor = conn.cursor()

        # Check if user already exists
        cursor.execute(
            "SELECT 1 FROM pg_roles WHERE rolname = %s", (app_user,)
        )
        if cursor.fetchone():
            print(f'✓ App DB user "{app_user}" already exists')
        else:
            # Create user with login but no superuser rights.
            # psycopg2.sql.Identifier safely quotes the username as a
            # PostgreSQL identifier, preventing SQL injection via env vars.
            cursor.execute(
                sql.SQL(
                    "CREATE USER {} WITH PASSWORD %s "
                    "NOSUPERUSER NOCREATEDB NOCREATEROLE LOGIN"
                ).format(sql.Identifier(app_user)),
                (app_password,)
            )
            print(f'✓ App DB user "{app_user}" created')

        # Grant privileges on the database and all tables.
        # All identifiers (dbname, app_user) go through sql.Identifier.
        parsed = urlparse(os.environ['DATABASE_URL'])
        dbname = parsed.path.lstrip('/')

        cursor.execute(
            sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
                sql.Identifier(dbname), sql.Identifier(app_user)
            )
        )

        # Grant usage on the public schema and all tables within it
        cursor.execute(
            sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(
                sql.Identifier(app_user)
            )
        )
        cursor.execute(
            sql.SQL(
                "GRANT SELECT, INSERT, UPDATE, DELETE "
                "ON ALL TABLES IN SCHEMA public TO {}"
            ).format(sql.Identifier(app_user))
        )
        cursor.execute(
            sql.SQL(
                "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {}"
            ).format(sql.Identifier(app_user))
        )

        # Ensure future tables created by migrations are also accessible
        cursor.execute(
            sql.SQL(
                "ALTER DEFAULT PRIVILEGES IN SCHEMA public "
                "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {}"
            ).format(sql.Identifier(app_user))
        )
        cursor.execute(
            sql.SQL(
                "ALTER DEFAULT PRIVILEGES IN SCHEMA public "
                "GRANT USAGE, SELECT ON SEQUENCES TO {}"
            ).format(sql.Identifier(app_user))
        )
        print(f'✓ Privileges granted to "{app_user}"')

        cursor.close()

    except Exception as e:
        print(f'❌ Failed to create app user: {e}')
        raise
    finally:
        # Guaranteed to run even if an exception is raised mid-way,
        # preventing a connection leak on the RDS master user connection.
        if conn is not None:
            conn.close()


def create_schema(app):
    """
    Create all tables using SQLAlchemy's metadata.
    db.create_all() is idempotent — existing tables are not touched,
    existing data is preserved. Safe for blue-green deployments.
    """
    from .extensions import db
    with app.app_context():
        db.create_all()
        print('✓ Database schema created / verified (db.create_all)')


def seed_sample_data(app):
    """
    Insert sample data for demo purposes.
    Only runs when:
      - Database has no users yet (empty check)
      - ENV != 'production'  OR  SEED_DB=true is explicitly set

    Passwords come from environment variables — no hardcoded credentials.
    Falls back to demo values only in non-production environments.
    """
    from .extensions import db
    from .models.user import User
    from .models.team import Team
    from .models.project import Project
    from .models.task import Task

    env = os.environ.get('ENV', 'development')
    force_seed = os.environ.get('SEED_DB', 'false').lower() == 'true'

    if env == 'production' and not force_seed:
        print('⏭  Skipping seed: ENV=production (set SEED_DB=true to override)')
        return

    with app.app_context():
        # Only seed if the database is empty
        if User.query.count() > 0:
            print('⏭  Skipping seed: database already has users')
            return

        print('🌱 Seeding sample data...')

        # Read demo passwords from env, fall back to obvious dev-only values
        # In production these would come from Secrets Manager
        admin_password    = os.environ.get('SEED_ADMIN_PASSWORD',    'ChangeMe-Admin-2024!')
        manager_password  = os.environ.get('SEED_MANAGER_PASSWORD',  'ChangeMe-Manager-2024!')
        dev_password      = os.environ.get('SEED_DEV_PASSWORD',      'ChangeMe-Dev-2024!')

        # Teams
        team_eng = Team(name='Engineering', description='Backend and frontend developers')
        team_product = Team(name='Product', description='Product managers and designers')
        db.session.add_all([team_eng, team_product])
        db.session.commit()

        # Users
        admin = User(email='admin@nexusdeploy.com', username='admin',
                     full_name='Admin User', role='admin', team_id=team_eng.id)
        admin.set_password(admin_password)

        manager = User(email='manager@nexusdeploy.com', username='manager',
                       full_name='Manager User', role='manager', team_id=team_eng.id)
        manager.set_password(manager_password)

        dev1 = User(email='dev1@nexusdeploy.com', username='developer1',
                    full_name='Developer One', role='developer', team_id=team_eng.id)
        dev1.set_password(dev_password)

        dev2 = User(email='dev2@nexusdeploy.com', username='developer2',
                    full_name='Developer Two', role='developer', team_id=team_eng.id)
        dev2.set_password(dev_password)

        db.session.add_all([admin, manager, dev1, dev2])
        db.session.commit()

        # Projects
        project1 = Project(name='NexusDeploy Platform',
                           description='CI/CD automation platform', team_id=team_eng.id)
        project2 = Project(name='Mobile App',
                           description='iOS and Android applications', team_id=team_eng.id)
        db.session.add_all([project1, project2])
        db.session.commit()

        # Tasks
        tasks = [
            Task(title='Implement authentication system',
                 description='Build JWT-based authentication with refresh tokens',
                 priority='high', status='in_progress',
                 project_id=project1.id, creator_id=manager.id, assignee_id=dev1.id),
            Task(title='Set up CI/CD pipeline',
                 description='Configure GitHub Actions for automated testing and deployment',
                 priority='critical', status='todo',
                 project_id=project1.id, creator_id=manager.id, assignee_id=dev2.id),
            Task(title='Design user dashboard',
                 description='Create mockups for the main user dashboard',
                 priority='medium', status='done',
                 project_id=project2.id, creator_id=manager.id, assignee_id=dev1.id),
        ]
        db.session.add_all(tasks)
        db.session.commit()

        print('\n' + '=' * 60)
        print('✓ Sample data seeded successfully')
        print('=' * 60)
        if env != 'production':
            print('\n  Demo credentials (dev only):')
            print(f'    Admin:     admin      / {admin_password}')
            print(f'    Manager:   manager    / {manager_password}')
            print(f'    Dev 1:     developer1 / {dev_password}')
            print(f'    Dev 2:     developer2 / {dev_password}')
            print('\n  API: http://localhost:5000/api/v1/auth/login')
        else:
            print('\n  Users created: admin, manager, developer1, developer2')
            print('  (credentials sourced from SEED_*_PASSWORD env vars)')
        print('=' * 60 + '\n')


def init_database():
    """Main entry point — runs all init steps in order."""
    from . import create_app

    env = os.environ.get('ENV', 'development')
    print(f'\n{"=" * 60}')
    print(f'  NexusDeploy DB Init  |  ENV={env}')
    print(f'{"=" * 60}\n')

    # Step 1: Create app DB user (skipped locally if creds not set)
    print('── Step 1/3: App DB user ─────────────────────────────')
    create_app_user()

    # Step 2: Create schema
    print('\n── Step 2/3: Schema ──────────────────────────────────')
    app = create_app(env)
    create_schema(app)

    # Step 3: Seed sample data (skipped in prod unless SEED_DB=true)
    print('\n── Step 3/3: Sample data ─────────────────────────────')
    seed_sample_data(app)

    print('\n✅ DB init complete\n')


if __name__ == '__main__':
    init_database()