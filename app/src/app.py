import logging
import time
import os
from flask import Flask, app, jsonify
from sqlalchemy import text
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from .config import config
from .extensions import db, migrate, jwt, limiter, cors, init_redis, init_celery, swagger

# Metrics
REQUEST_COUNT = Counter('app_requests_total', 'Total requests', [
                        'method', 'endpoint', 'status'])
REQUEST_LATENCY = Histogram(
    'app_request_latency_seconds', 'Request latency', ['endpoint'])


def create_app(config_name='default'):
    """Application factory"""
    app = Flask(__name__)
    app.config.from_object(config[config_name])

    # Validate production secrets with clear error messages
    if config_name == 'production':
        if not app.config.get('SECRET_KEY'):
            app.logger.critical(
                'STARTUP FAILED: ENV is set to "production" but SECRET_KEY '
                'environment variable is not set. Set SECRET_KEY before starting.'
            )
            raise RuntimeError(
                'SECRET_KEY environment variable is required in production. '
                'Set SECRET_KEY before starting the application.'
            )
        if not app.config.get('JWT_SECRET_KEY'):
            app.logger.critical(
                'STARTUP FAILED: ENV is set to "production" but JWT_SECRET_KEY '
                'environment variable is not set. Set JWT_SECRET_KEY or SECRET_KEY '
                'before starting.'
            )
            raise RuntimeError(
                'JWT_SECRET_KEY or SECRET_KEY environment variable is required in production. '
                'Set at least one before starting the application.'
            )

    # Initialize extensions
    db.init_app(app)
    migrate.init_app(app, db)
    jwt.init_app(app)
    limiter.init_app(app)
    cors.init_app(app)
    init_redis(app)
    init_celery(app)

    # Swagger configuration
    app.config['SWAGGER'] = {
        'title': 'NexusDeploy Project Management API',
        'version': app.config['VERSION'],
        'description': 'Production-grade project management API',
        'termsOfService': '',
        'hide_top_bar': False,
        'securityDefinitions': {
            'Bearer': {
                'type': 'apiKey',
                'name': 'Authorization',
                'in': 'header',
                'description': 'JWT Authorization header. Example: "Bearer {token}"'
            }
        },
        'security': [
            {
                'Bearer': []
            }
        ]
    }
    swagger.init_app(app)

    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s %(levelname)s %(name)s: %(message)s'
    )

    # Register blueprints
    from .api.v1 import api_v1
    app.register_blueprint(api_v1, url_prefix='/api/v1')

    # Metrics middleware
    @app.before_request
    def before_request():
        from flask import request
        request.start_time = time.time()

    @app.after_request
    def after_request(response):
        from flask import request
        if hasattr(request, 'start_time'):
            latency = time.time() - request.start_time
            REQUEST_LATENCY.labels(
                endpoint=request.endpoint or 'unknown').observe(latency)
            REQUEST_COUNT.labels(
                method=request.method,
                endpoint=request.endpoint or 'unknown',
                status=response.status_code
            ).inc()
        return response

    # Health checks
    @app.route('/health')
    def health():
        from .extensions import redis_client
        try:
            db.session.execute(text('SELECT 1'))
            db_status = 'healthy'
        except Exception as e:
            app.logger.error(f"Database health check failed: {e}")
            db_status = 'unhealthy'
            return jsonify({
                'status': 'unhealthy',
                'database': db_status,
                'version': app.config['VERSION']
            }), 503

        try:
            redis_client.ping()
            redis_status = 'healthy'
        except Exception as e:
            app.logger.error(f"Redis health check failed: {e}")
            redis_status = 'unhealthy'

        overall_status = 'healthy' if redis_status == 'healthy' else 'unhealthy'
        http_code = 200 if overall_status == 'healthy' else 503

        return jsonify({
            'status': overall_status,
            'database': db_status,
            'redis': redis_status,
            'version': app.config['VERSION'],
            'environment': app.config['ENV']
        }), http_code

    @app.route('/ready')
    def ready():
        return jsonify({'ready': True}), 200

    @app.route('/metrics')
    def metrics():
        return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}

    @app.route('/')
    def home():
        return jsonify({
            'message': 'NexusDeploy Project Management API',
            'version': app.config['VERSION'],
            'environment': app.config['ENV'],
            'documentation': '/apidocs'
        }), 200

    @app.errorhandler(404)
    def not_found(error):
        return jsonify({'error': 'Not found'}), 404

    @app.errorhandler(500)
    def internal_error(error):
        app.logger.error(f'Internal error: {error}')
        db.session.rollback()
        return jsonify({'error': 'Internal server error'}), 500

    return app
