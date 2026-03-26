from unittest.mock import patch


def test_health_endpoint_structure(client):
    """Health endpoint returns expected keys"""
    response = client.get('/health')
    # Will be 503 in test env since Redis isn't running — check structure only
    assert response.json is not None
    assert 'status' in response.json
    assert 'database' in response.json
    assert 'version' in response.json


def test_health_database_up(client):
    """Database is healthy in test environment (SQLite in-memory)"""
    response = client.get('/health')
    assert response.json['database'] == 'healthy'


def test_health_redis_down_returns_503(client):
    """When Redis is unreachable, /health returns 503"""
    with patch('src.extensions.redis_client') as mock_redis:
        mock_redis.ping.side_effect = Exception('Redis connection refused')
        response = client.get('/health')

    assert response.status_code == 503
    assert response.json['status'] == 'unhealthy'
    assert response.json['redis'] == 'unhealthy'


def test_health_redis_up_returns_200(client):
    """When both DB and Redis are healthy, /health returns 200"""
    with patch('src.extensions.redis_client') as mock_redis:
        mock_redis.ping.return_value = True
        response = client.get('/health')

    assert response.status_code == 200
    assert response.json['status'] == 'healthy'
    assert response.json['database'] == 'healthy'
    assert response.json['redis'] == 'healthy'


def test_ready_endpoint(client):
    response = client.get('/ready')
    assert response.status_code == 200
    assert response.json['ready'] is True


def test_home_endpoint(client):
    response = client.get('/')
    assert response.status_code == 200
    assert 'message' in response.json
    assert 'version' in response.json
    assert 'documentation' in response.json


def test_404_handler(client):
    response = client.get('/api/v1/doesnotexist')
    assert response.status_code == 404
    assert 'error' in response.json
