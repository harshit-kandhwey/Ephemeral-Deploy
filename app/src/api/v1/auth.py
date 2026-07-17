import math
import time

from flask import current_app, jsonify, request
from flask_jwt_extended import (
    create_access_token,
    create_refresh_token,
    decode_token,
    get_jwt,
    get_jwt_identity,
    jwt_required,
)

from ...extensions import db, limiter, redis_client
from ...models.audit_log import AuditLog
from ...models.user import User
from ...utils.decorators import get_current_user_or_401
from ...utils.validation import ValidationError, get_json_body, require_fields, validate_password
from . import api_v1


def _revoke_token(payload):
    """Blocklist a decoded JWT until its own expiry.

    Keyed by jti with a TTL matching the token's remaining lifetime, so the
    entry evicts itself once the token would have expired anyway.
    """
    jti = payload["jti"]
    ttl = max(math.ceil(payload["exp"] - time.time()), 1)
    redis_client.setex(f"jti_blocklist:{jti}", ttl, "revoked")


@api_v1.route("/auth/register", methods=["POST"])
@limiter.limit("5 per hour")
def register():
    """
    Register a new user
    ---
    tags:
      - Authentication
    parameters:
      - name: body
        in: body
        required: true
        schema:
          type: object
          required:
            - email
            - username
            - password
          properties:
            email:
              type: string
            username:
              type: string
            password:
              type: string
            full_name:
              type: string
    responses:
      201:
        description: User created successfully
      400:
        description: Validation error
    """
    try:
        data = get_json_body(request, required=True)
        require_fields(data, "email", "username", "password")
        validate_password(data["password"], current_app.config["MIN_PASSWORD_LENGTH"])
    except ValidationError as e:
        return jsonify({"error": e.message}), 400

    # Check if user exists
    if User.query.filter_by(email=data["email"]).first():
        return jsonify({"error": "Email already registered"}), 400

    if User.query.filter_by(username=data["username"]).first():
        return jsonify({"error": "Username already taken"}), 400

    # Create user
    user = User(
        email=data["email"],
        username=data["username"],
        full_name=data.get("full_name", ""),
    )
    user.set_password(data["password"])

    db.session.add(user)
    db.session.commit()

    # Audit log
    audit = AuditLog(
        user_id=user.id,
        action="created",
        entity_type="user",
        entity_id=user.id,
        ip_address=request.remote_addr,
        user_agent=request.user_agent.string,
    )
    db.session.add(audit)
    db.session.commit()

    return (
        jsonify(
            {
                "message": "User created successfully",
                "user": user.to_dict(include_email=True),
            }
        ),
        201,
    )


@api_v1.route("/auth/login", methods=["POST"])
@limiter.limit("10 per minute")
def login():
    """
    Login and get JWT tokens
    ---
    tags:
      - Authentication
    parameters:
      - name: body
        in: body
        required: true
        schema:
          type: object
          required:
            - username
            - password
          properties:
            username:
              type: string
            password:
              type: string
    responses:
      200:
        description: Login successful
      401:
        description: Invalid credentials
    """
    try:
        data = get_json_body(request, required=True)
        require_fields(data, "username", "password")
    except ValidationError as e:
        return jsonify({"error": e.message}), 400

    user = User.query.filter_by(username=data["username"]).first()

    if not user or not user.check_password(data["password"]):
        # Audit failed attempts too — a trail that only records successes cannot
        # evidence a brute-force attempt. user_id is nullable, but entity_id is
        # NOT NULL, so an unknown username uses 0 as the "no such user" sentinel
        # and the attempted name is preserved in `changes` for forensics.
        # The submitted password is never recorded.
        audit = AuditLog(
            user_id=user.id if user else None,
            action="login_failed",
            entity_type="auth",
            entity_id=user.id if user else 0,
            changes={"username": data["username"]},
            ip_address=request.remote_addr,
            user_agent=request.user_agent.string,
        )
        db.session.add(audit)
        db.session.commit()
        return jsonify({"error": "Invalid credentials"}), 401

    if not user.is_active:
        return jsonify({"error": "Account is disabled"}), 403

    # Create tokens
    access_token = create_access_token(identity=str(user.id))
    refresh_token = create_refresh_token(identity=str(user.id))

    # Audit log
    audit = AuditLog(
        user_id=user.id,
        action="login",
        entity_type="auth",
        entity_id=user.id,
        ip_address=request.remote_addr,
        user_agent=request.user_agent.string,
    )
    db.session.add(audit)
    db.session.commit()

    return (
        jsonify(
            {
                "access_token": access_token,
                "refresh_token": refresh_token,
                "user": user.to_dict(include_email=True),
            }
        ),
        200,
    )


@api_v1.route("/auth/refresh", methods=["POST"])
@jwt_required(refresh=True)
def refresh():
    """
    Refresh access token
    ---
    tags:
      - Authentication
    security:
      - Bearer: []
    responses:
      200:
        description: Token refreshed
      403:
        description: Account disabled
    """
    user_id = int(get_jwt_identity())
    user = User.query.get(user_id)
    if not user or not user.is_active:
        return jsonify({"error": "Account is disabled"}), 403
    access_token = create_access_token(identity=str(user_id))
    return jsonify({"access_token": access_token}), 200


@api_v1.route("/auth/logout", methods=["POST"])
@jwt_required()
def logout():
    """
    Revoke the current session's tokens

    Always revokes the access token presented on this request. If the client
    also sends its refresh token in the body as ``refresh_token``, that token is
    revoked too — otherwise the long-lived refresh token would survive logout
    and could mint fresh access tokens after the user "logged out".
    ---
    tags:
      - Authentication
    security:
      - Bearer: []
    parameters:
      - name: body
        in: body
        required: false
        schema:
          type: object
          properties:
            refresh_token:
              type: string
    responses:
      200:
        description: Logged out successfully
      400:
        description: Malformed refresh token
    """
    if redis_client is None:
        current_app.logger.error("Redis unavailable; cannot revoke JWT")
        return jsonify({"error": "Logout temporarily unavailable"}), 503

    # get_json returns the parsed value as-is for valid non-object JSON (e.g.
    # [] or "token"), so guard the type before calling .get() to avoid a 500.
    body = request.get_json(silent=True) or {}
    if not isinstance(body, dict):
        return jsonify({"error": "Request body must be a JSON object"}), 400
    refresh_token = body.get("refresh_token")

    # Validate the optional refresh token up front, but a bad one must NOT stop
    # us from revoking the caller's own access token — logout always ends the
    # presented session. A refresh token is only revoked when it decodes AND
    # belongs to the caller (an access token or another user's token is
    # rejected without being revoked).
    refresh_payload = None
    refresh_invalid = False
    if refresh_token:
        try:
            decoded = decode_token(refresh_token)
        except Exception:
            decoded = None
        if decoded and decoded.get("type") == "refresh" and decoded.get("sub") == get_jwt_identity():
            refresh_payload = decoded
        else:
            refresh_invalid = True

    try:
        _revoke_token(get_jwt())
        if refresh_payload:
            _revoke_token(refresh_payload)
    except Exception:
        current_app.logger.exception("Failed to revoke JWT")
        return jsonify({"error": "Logout temporarily unavailable"}), 503

    if refresh_invalid:
        return jsonify({"error": "Invalid refresh token"}), 400

    return jsonify({"message": "Logged out successfully"}), 200


@api_v1.route("/auth/me", methods=["GET"])
@jwt_required()
def get_current_user():
    """
    Get current user info
    ---
    tags:
      - Authentication
    security:
      - Bearer: []
    responses:
      200:
        description: Current user details
      403:
        description: Account disabled
    """
    # get_current_user_or_401 rejects disabled accounts (403) — a token minted
    # before the account was deactivated must not keep working.
    user, error_response = get_current_user_or_401()
    if error_response:
        return error_response
    return jsonify(user.to_dict(include_email=True)), 200
