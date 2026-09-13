from unittest.mock import MagicMock

from src.utils.pagination import paginate


def _fake_paginated_query(total_items, page, per_page):
    """A stand-in for Flask-SQLAlchemy's Pagination object, carrying only
    the attributes paginate() reads."""
    result = MagicMock()
    result.items = list(range(min(per_page, max(total_items - (page - 1) * per_page, 0))))
    result.total = total_items
    result.pages = max((total_items + per_page - 1) // per_page, 1)
    result.page = page
    result.has_next = page * per_page < total_items
    result.has_prev = page > 1
    return result


def test_paginate_shapes_the_expected_keys():
    query = MagicMock()
    query.paginate.return_value = _fake_paginated_query(total_items=5, page=1, per_page=20)

    result = paginate(query, page=1, per_page=20)

    assert set(result.keys()) == {"items", "total", "pages", "current_page", "has_next", "has_prev"}
    assert result["total"] == 5
    assert result["current_page"] == 1
    assert result["has_next"] is False
    assert result["has_prev"] is False


def test_paginate_caps_per_page_at_100():
    """A caller asking for per_page=99999 must not reach the DB with that
    value uncapped — this is the one real guarantee this module makes."""
    query = MagicMock()
    query.paginate.return_value = _fake_paginated_query(total_items=500, page=1, per_page=100)

    paginate(query, page=1, per_page=99999)

    _, kwargs = query.paginate.call_args
    assert kwargs["per_page"] == 100


def test_paginate_does_not_cap_a_request_under_the_limit():
    """The cap must be a ceiling, not a fixed override — proves the guard
    isn't silently forcing every request to 100 regardless of input."""
    query = MagicMock()
    query.paginate.return_value = _fake_paginated_query(total_items=500, page=1, per_page=10)

    paginate(query, page=1, per_page=10)

    _, kwargs = query.paginate.call_args
    assert kwargs["per_page"] == 10


def test_paginate_passes_error_out_false():
    """error_out=False means an out-of-range page returns an empty page
    instead of raising a 404 inside a helper meant to be reusable — a
    caller wanting the 404 behavior would need its own check."""
    query = MagicMock()
    query.paginate.return_value = _fake_paginated_query(total_items=0, page=1, per_page=20)

    paginate(query, page=999, per_page=20)

    _, kwargs = query.paginate.call_args
    assert kwargs["error_out"] is False
