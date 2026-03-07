#!/usr/bin/env bash
# healthcheck.sh — verify that the edge gateway is healthy.
# Used as a Docker HEALTHCHECK and can also be run manually.
set -euo pipefail

HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" http://localhost/healthz)

if [ "$HTTP_CODE" = "200" ]; then
    echo "healthy (HTTP $HTTP_CODE)"
    exit 0
else
    echo "unhealthy (HTTP $HTTP_CODE)" >&2
    exit 1
fi
