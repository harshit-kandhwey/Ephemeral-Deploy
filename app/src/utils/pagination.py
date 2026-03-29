def paginate(query, page=1, per_page=20):
    """Helper for pagination"""
    items = query.paginate(page=page, per_page=min(per_page, 100), error_out=False)

    return {
        "items": items.items,
        "total": items.total,
        "pages": items.pages,
        "current_page": items.page,
        "has_next": items.has_next,
        "has_prev": items.has_prev,
    }
