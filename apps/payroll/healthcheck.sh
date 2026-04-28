#!/usr/bin/env bash
# Vibe Payroll Time healthcheck.
# Single-app: hits the bundled Caddy on CADDY_HTTP_PORT.
# Multi-app:  the bundled Caddy is disabled — use lib/checks.sh::check_app_http.

set -euo pipefail

PORT="${CADDY_HTTP_PORT:-80}"
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
