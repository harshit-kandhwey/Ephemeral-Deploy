import json
import urllib.error
from unittest.mock import MagicMock, patch

from src import smoke_test


def _mock_response(status, body_dict):
    resp = MagicMock()
    resp.status = status
    resp.read.return_value = json.dumps(body_dict).encode()
    resp.__enter__.return_value = resp
    return resp


def test_main_fails_without_target(monkeypatch):
    monkeypatch.delenv("SMOKE_TEST_TARGET_URL", raising=False)
    monkeypatch.setenv("SEED_ADMIN_PASSWORD", "x")
    assert smoke_test.main() == 1


def test_main_fails_without_admin_password(monkeypatch):
    monkeypatch.setenv("SMOKE_TEST_TARGET_URL", "http://10.0.0.1:5000")
    monkeypatch.delenv("SEED_ADMIN_PASSWORD", raising=False)
    assert smoke_test.main() == 1


def test_main_succeeds_on_healthy_target_and_valid_login(monkeypatch):
    monkeypatch.setenv("SMOKE_TEST_TARGET_URL", "http://10.0.0.1:5000")
    monkeypatch.setenv("SEED_ADMIN_PASSWORD", "correct-password")

    health_resp = _mock_response(200, {})
    login_resp = _mock_response(200, {"access_token": "abc123"})

    with patch("src.smoke_test.urllib.request.urlopen", side_effect=[health_resp, login_resp]) as mock_urlopen:
        assert smoke_test.main() == 0

    # First call hits /health, second POSTs the login payload with the
    # actual admin password — proves the right credentials were sent, not
    # just that *some* request succeeded.
    assert mock_urlopen.call_count == 2
    first_call_url = mock_urlopen.call_args_list[0].args[0]
    assert first_call_url == "http://10.0.0.1:5000/health"
    second_call_req = mock_urlopen.call_args_list[1].args[0]
    sent_body = json.loads(second_call_req.data)
    assert sent_body == {"username": "admin", "password": "correct-password"}


def test_main_fails_when_health_check_is_not_200(monkeypatch):
    monkeypatch.setenv("SMOKE_TEST_TARGET_URL", "http://10.0.0.1:5000")
    monkeypatch.setenv("SEED_ADMIN_PASSWORD", "correct-password")

    unhealthy_resp = _mock_response(503, {})

    with patch("src.smoke_test.urllib.request.urlopen", return_value=unhealthy_resp):
        assert smoke_test.main() == 1


def test_main_fails_when_login_response_has_no_access_token(monkeypatch):
    """Plant-confirmed: without this assertion, a 200 with an empty body
    would wrongly read as success."""
    monkeypatch.setenv("SMOKE_TEST_TARGET_URL", "http://10.0.0.1:5000")
    monkeypatch.setenv("SEED_ADMIN_PASSWORD", "correct-password")

    health_resp = _mock_response(200, {})
    login_resp = _mock_response(200, {"message": "ok but no token"})

    with patch("src.smoke_test.urllib.request.urlopen", side_effect=[health_resp, login_resp]):
        assert smoke_test.main() == 1


def test_main_fails_on_401_invalid_credentials(monkeypatch):
    monkeypatch.setenv("SMOKE_TEST_TARGET_URL", "http://10.0.0.1:5000")
    monkeypatch.setenv("SEED_ADMIN_PASSWORD", "wrong-password")

    health_resp = _mock_response(200, {})
    unauthorized_error = urllib.error.HTTPError(
        url="http://10.0.0.1:5000/api/v1/auth/login", code=401, msg="Unauthorized", hdrs=None, fp=None
    )

    with patch("src.smoke_test.urllib.request.urlopen", side_effect=[health_resp, unauthorized_error]):
        assert smoke_test.main() == 1


def test_main_fails_on_connection_error(monkeypatch):
    monkeypatch.setenv("SMOKE_TEST_TARGET_URL", "http://10.0.0.1:5000")
    monkeypatch.setenv("SEED_ADMIN_PASSWORD", "correct-password")

    with patch("src.smoke_test.urllib.request.urlopen", side_effect=urllib.error.URLError("connection refused")):
        assert smoke_test.main() == 1
