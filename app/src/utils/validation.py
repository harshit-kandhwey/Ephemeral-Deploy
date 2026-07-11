"""
Request-validation helpers.

These exist to keep unvalidated request data from reaching SQLAlchemy, where a
bad value surfaces as a database error and a 500 rather than a 400. Every helper
returns the parsed value or raises ValidationError, which the API layer converts
into a clean JSON error response.
"""

from datetime import datetime

# Allowed values, mirroring the columns they guard (see models/task.py and
# models/project.py). Kept here so the API layer is the single place that
# rejects an unknown value — the DB columns are plain strings and would
# happily store anything.
TASK_STATUSES = ("todo", "in_progress", "in_review", "done")
TASK_PRIORITIES = ("low", "medium", "high", "critical")
PROJECT_STATUSES = ("active", "archived", "on_hold")
USER_ROLES = ("admin", "manager", "developer")


class ValidationError(Exception):
    """Raised when request data fails validation. Carries the client-facing message."""

    def __init__(self, message):
        super().__init__(message)
        self.message = message


def get_json_body(request, required=False):
    """
    Return the parsed JSON body as a dict.

    A body of `null`, a bare list, or malformed JSON all parse to something that
    is not a dict — and `"key" in data` then raises TypeError, producing a 500.
    silent=True keeps a malformed body from raising before we can check it.
    """
    data = request.get_json(silent=True)

    if data is None:
        if required:
            raise ValidationError("Request body must be a JSON object")
        return {}

    if not isinstance(data, dict):
        raise ValidationError("Request body must be a JSON object")

    return data


def require_fields(data, *fields):
    """Raise if any required key is absent. Reports every missing field at once."""
    missing = [f for f in fields if f not in data]
    if missing:
        raise ValidationError(f'Missing required fields: {", ".join(missing)}')


def validate_choice(value, allowed, field):
    """Raise unless value is one of `allowed`."""
    if value not in allowed:
        raise ValidationError(f'Invalid {field}. Must be one of: {", ".join(allowed)}')
    return value


def parse_int(value, field):
    """Coerce to int or raise. Booleans are rejected — bool is an int subclass in Python."""
    if isinstance(value, bool):
        raise ValidationError(f"{field} must be an integer")
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"{field} must be an integer") from exc


def parse_datetime(value, field):
    """
    Parse an ISO-8601 datetime or raise.

    datetime.fromisoformat raises ValueError on anything it cannot parse, which
    is a 500 if it escapes the request handler.
    """
    if not isinstance(value, str):
        raise ValidationError(f"{field} must be an ISO-8601 datetime string")
    try:
        return datetime.fromisoformat(value)
    except ValueError as exc:
        raise ValidationError(f"{field} must be a valid ISO-8601 datetime (e.g. 2026-01-31T14:30:00)") from exc


def resolve_entity(session, model, entity_id, field):
    """
    Load a referenced row or raise.

    Without this the bad id reaches the database as a foreign-key violation:
    an IntegrityError, a 500, and a poisoned session — instead of a 400 naming
    the offending field.
    """
    parsed_id = parse_int(entity_id, field)
    entity = session.get(model, parsed_id)
    if entity is None:
        raise ValidationError(f"{field} {parsed_id} does not exist")
    return entity


def validate_password(password, min_length=8):
    """
    Validate a plaintext password.

    The 72-byte ceiling is bcrypt's: it silently truncates anything longer, so a
    128-character passphrase would really be its first 72 bytes. Rejecting the
    input is honest; accepting and truncating it is not. Length is measured in
    UTF-8 bytes because that is what bcrypt actually hashes.
    """
    if not isinstance(password, str):
        raise ValidationError("Password must be a string")

    if len(password) < min_length:
        raise ValidationError(f"Password must be at least {min_length} characters")

    if len(password.encode("utf-8")) > 72:
        raise ValidationError("Password must be at most 72 bytes (bcrypt truncates beyond this)")

    return password
