#!/usr/bin/env python3
"""Container health check probe — replaces curl, absent from the
distroless runtime image. See docs/design-decisions.md#distroless-runtime-images.
"""

import sys
import urllib.request

try:
    with urllib.request.urlopen("http://localhost:5000/health", timeout=3) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except Exception:
    sys.exit(1)
