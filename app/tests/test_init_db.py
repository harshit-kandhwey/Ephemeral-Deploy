from unittest.mock import MagicMock, patch

import pytest

from src import create_app
from src.extensions import db
from src.init_db import _get_master_conn, create_app_user, create_schema, seed_sample_data
from src.models.project import Project
from src.models.task import Task
from src.models.team import Team
from src.models.user import User

# ── _get_master_conn / create_app_user ───────────────────────────────────────


def test_create_app_user_skips_when_app_user_env_unset(monkeypatch):
    """Local-dev path: no DB_APP_USER/PASSWORD means the app connects as
    the postgres superuser directly — must not even attempt a connection."""
    monkeypatch.delenv("DB_APP_USER", raising=False)
    monkeypatch.delenv("DB_APP_PASSWORD", raising=False)
    with patch("src.init_db.psycopg2.connect") as mock_connect:
        create_app_user()
    mock_connect.assert_not_called()


def test_get_master_conn_raises_without_database_url(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(RuntimeError, match="DATABASE_URL"):
        _get_master_conn()


def test_get_master_conn_raises_without_master_credentials(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "postgresql://x:y@host:5432/db")
    monkeypatch.delenv("DB_MASTER_USER", raising=False)
    monkeypatch.delenv("DB_MASTER_PASSWORD", raising=False)
    with pytest.raises(RuntimeError, match="DB_MASTER_USER"):
        _get_master_conn()


def test_get_master_conn_raises_with_only_one_master_credential_set(monkeypatch):
    """Mutmut-caught gap: the fail-closed check is `not user or not password`,
    not `and` — a partial credential pair (one env var set, the other absent)
    must still raise, not silently proceed with a None value."""
    monkeypatch.setenv("DATABASE_URL", "postgresql://x:y@host:5432/db")
    monkeypatch.setenv("DB_MASTER_USER", "master")
    monkeypatch.delenv("DB_MASTER_PASSWORD", raising=False)
    with pytest.raises(RuntimeError, match="DB_MASTER_USER"):
        _get_master_conn()


def _mock_cursor(role_exists):
    cursor = MagicMock()
    cursor.fetchone.return_value = (1,) if role_exists else None
    return cursor


def _setup_master_conn_mocks(monkeypatch, role_exists):
    monkeypatch.setenv("DATABASE_URL", "postgresql://x:y@host:5432/nexusdeploy")
    monkeypatch.setenv("DB_MASTER_USER", "nexusadmin")
    monkeypatch.setenv("DB_MASTER_PASSWORD", "masterpw")
    monkeypatch.setenv("DB_APP_USER", "nexusapp")
    monkeypatch.setenv("DB_APP_PASSWORD", "apppw")
    cursor = _mock_cursor(role_exists)
    conn = MagicMock()
    conn.cursor.return_value = cursor
    return conn, cursor


def test_create_app_user_creates_when_missing(monkeypatch):
    conn, cursor = _setup_master_conn_mocks(monkeypatch, role_exists=False)
    with patch("src.init_db.psycopg2.connect", return_value=conn):
        create_app_user()
    # SELECT existence check + CREATE USER + 6 GRANT/ALTER statements = 8
    assert cursor.execute.call_count == 8
    create_user_calls = [c for c in cursor.execute.call_args_list if "CREATE USER" in str(c)]
    assert len(create_user_calls) == 1


def test_create_app_user_skips_create_when_role_exists(monkeypatch):
    conn, cursor = _setup_master_conn_mocks(monkeypatch, role_exists=True)
    with patch("src.init_db.psycopg2.connect", return_value=conn):
        create_app_user()
    # One fewer call than the "create" case — no CREATE USER statement.
    assert cursor.execute.call_count == 7
    create_user_calls = [c for c in cursor.execute.call_args_list if "CREATE USER" in str(c)]
    assert len(create_user_calls) == 0


def test_create_app_user_closes_connection_even_on_failure(monkeypatch):
    conn, cursor = _setup_master_conn_mocks(monkeypatch, role_exists=True)
    cursor.execute.side_effect = [None, RuntimeError("grant failed")]
    with patch("src.init_db.psycopg2.connect", return_value=conn):
        with pytest.raises(RuntimeError, match="grant failed"):
            create_app_user()
    conn.close.assert_called_once()


# ── create_schema ─────────────────────────────────────────────────────────────


def test_create_schema_creates_queryable_tables():
    fresh_app = create_app("testing")
    create_schema(fresh_app)
    with fresh_app.app_context():
        assert User.query.count() == 0  # no exception means the table exists
        db.drop_all()


# ── seed_sample_data ────────────────────────────────────────────────────────

_ALL_SEED_KEYS = ("SEED_ADMIN_PASSWORD", "SEED_MANAGER_PASSWORD", "SEED_DEV_PASSWORD")


def _clear_seed_env(monkeypatch):
    for key in _ALL_SEED_KEYS:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.delenv("SEED_DB", raising=False)


def test_seed_raises_when_non_development_and_seed_passwords_missing(app, monkeypatch):
    monkeypatch.setenv("ENV", "staging")
    _clear_seed_env(monkeypatch)

    with app.app_context():
        with pytest.raises(RuntimeError, match="SEED_ADMIN_PASSWORD"):
            seed_sample_data(app)
        assert User.query.count() == 0  # fails BEFORE touching the DB


def test_seed_raises_naming_only_the_missing_key(app, monkeypatch):
    """Catches an off-by-something in the missing-list comprehension that
    the all-missing case alone wouldn't."""
    monkeypatch.setenv("ENV", "staging")
    _clear_seed_env(monkeypatch)
    monkeypatch.setenv("SEED_ADMIN_PASSWORD", "a")
    monkeypatch.setenv("SEED_MANAGER_PASSWORD", "b")
    # SEED_DEV_PASSWORD deliberately left unset

    with app.app_context():
        with pytest.raises(RuntimeError) as excinfo:
            seed_sample_data(app)
    assert "SEED_DEV_PASSWORD" in str(excinfo.value)
    assert "SEED_ADMIN_PASSWORD" not in str(excinfo.value)
    assert "SEED_MANAGER_PASSWORD" not in str(excinfo.value)


def test_seed_succeeds_in_development_without_seed_passwords(app, monkeypatch):
    monkeypatch.setenv("ENV", "development")
    _clear_seed_env(monkeypatch)

    with app.app_context():
        seed_sample_data(app)
        assert User.query.filter_by(username="admin").first() is not None


def test_seed_succeeds_outside_development_when_all_seed_passwords_set(app, client, monkeypatch):
    monkeypatch.setenv("ENV", "staging")
    _clear_seed_env(monkeypatch)
    monkeypatch.setenv("SEED_ADMIN_PASSWORD", "provided-admin-pw-123")
    monkeypatch.setenv("SEED_MANAGER_PASSWORD", "provided-manager-pw-123")
    monkeypatch.setenv("SEED_DEV_PASSWORD", "provided-dev-pw-123")

    with app.app_context():
        seed_sample_data(app)

    # Proves the PROVIDED password was used, not the ChangeMe-* fallback.
    response = client.post(
        "/api/v1/auth/login",
        json={"username": "admin", "password": "provided-admin-pw-123"},
    )
    assert response.status_code == 200
    assert "access_token" in response.json


def test_seed_skips_when_users_already_exist(app, monkeypatch):
    monkeypatch.setenv("ENV", "development")
    _clear_seed_env(monkeypatch)

    with app.app_context():
        team = Team(name="Pre-existing")
        db.session.add(team)
        db.session.commit()
        existing = User(email="x@x.com", username="existing", full_name="Existing", team_id=team.id)
        existing.set_password("whatever")
        db.session.add(existing)
        db.session.commit()

        seed_sample_data(app)

        assert Team.query.count() == 1  # still just the pre-existing one
        assert Project.query.count() == 0
        assert Task.query.count() == 0


def test_seed_skips_in_production_without_force_seed(app, monkeypatch):
    """A distinct, EARLIER guard than the password check — a suite that
    only exercises the fail-closed branch would miss a regression here."""
    monkeypatch.setenv("ENV", "production")
    _clear_seed_env(monkeypatch)

    with app.app_context():
        seed_sample_data(app)  # must not raise
        assert User.query.count() == 0


def test_seed_happy_path_creates_expected_counts_and_relationships(app, monkeypatch):
    monkeypatch.setenv("ENV", "development")
    _clear_seed_env(monkeypatch)

    with app.app_context():
        seed_sample_data(app)

        assert Team.query.count() == 2
        assert User.query.count() == 4
        assert Project.query.count() == 2
        assert Task.query.count() == 3

        auth_task = Task.query.filter_by(title="Implement authentication system").first()
        assert auth_task is not None
        assert auth_task.assignee.username == "developer1"
