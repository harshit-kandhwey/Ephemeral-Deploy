#!/usr/bin/env python3
"""Container health check probe for the API image.

Replaces `curl -f http://localhost:5000/health`, which the distroless
runtime image has neither the shell nor the binary for. Used as the
Docker HEALTHCHECK instruction and as the ECS task definition's container
healthCheck command — both need exec-form (no shell), so this is invoked
directly rather than via an inline shell one-liner.
See docs/design-decisions.md#distroless-runtime-images.
"""

import sys
import urllib.request

try:
    with urllib.request.urlopen("http://localhost:5000/health", timeout=3) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except Exception:
    sys.exit(1)
