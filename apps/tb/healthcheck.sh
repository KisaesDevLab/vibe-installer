#!/usr/bin/env bash
# Vibe TB healthcheck.
# In single-app mode the api is reachable through the web container's nginx
# at /api/v1/health on the WEB_PUBLISH_PORT host port.

set -euo pipefail

PORT="${WEB_PUBLISH_PORT:-8081}"
URL="http://127.0.0.1:${PORT}/api/v1/health"

if ! command -v curl >/dev/null 2>&1; then
    echo "healthcheck: curl missing — cannot probe $URL" >&2
    exit 1
fi

response="$(curl -fsS --max-time 5 "$URL" 2>&1)" || {
    echo "healthcheck: $URL unreachable: $response" >&2
    exit 1
}

if printf '%s' "$response" | grep -qiE '"(status|ok)"[[:space:]]*:[[:space:]]*"?(ok|true|healthy)"?'; then
    echo "healthcheck: ok ($URL)"
    exit 0
else
    echo "healthcheck: ok ($URL — non-standard 2xx body)"
    exit 0
fi
