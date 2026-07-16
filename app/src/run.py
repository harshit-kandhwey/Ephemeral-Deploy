"""
Run the application locally for development
Usage: python -m app.src.run (from project root)
"""

from . import create_app

if __name__ == "__main__":
    app = create_app("development")
    # debug follows the app config (FLASK_DEBUG env var, default on for local
    # dev) rather than a hard-coded True. Hard-coding it enables the Werkzeug
    # debugger — an RCE console — anywhere this module happens to run, which is
    # what CodeQL's py/flask-debug flags.
    # nosec B104: binding all interfaces is intentional here — this local dev
    # runner must be reachable from the host / other docker-compose services.
    # It is never the production entrypoint (gunicorn is; see Dockerfile).
    app.run(host="0.0.0.0", port=5000, debug=app.config["DEBUG"])  # nosec B104
