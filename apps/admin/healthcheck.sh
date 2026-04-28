#!/usr/bin/env bash
# Vibe Admin healthcheck — invoked by `vibe doctor` and post-install verify.
# Probes the admin container's published host port; multi-app installs
# verify through Caddy via lib/checks.sh::check_app_http.

set -euo pipefail

PORT="${ADMIN_PUBLISH_PORT:-4500}"
URL="http://127.0.0.1:${PORT}/health"

if ! command -v curl >/dev/null 2>&1; then
    echo "healthcheck: curl missing — cannot probe $URL" >&2
    exit 1
fi

response="$(curl -fsS --max-time 5 "$URL" 2>&1)" || {
    echo "healthcheck: $URL unreachable: $response" >&2
    exit 1
}

if printf '%s' "$response" | grep -q '"ok":true'; then
    echo "healthcheck: ok ($URL)"
    exit 0
elif [ -n "$response" ]; then
    echo "healthcheck: ok ($URL — non-standard 2xx body)"
    exit 0
else
    echo "healthcheck: $URL returned empty body" >&2
    exit 1
fi
