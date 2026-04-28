#!/usr/bin/env bash
# Vibe Tax Research Chat healthcheck.
#
# Always-multi-app: probes the shared installer Caddy ingress at
# /tax/health, which the fragment routes to vibe-tax-api:4000/api/health.
# Falls back to the single-app published WEB_PUBLISH_PORT (default 8082)
# only if the ingress isn't up — useful for the developer-convenience
# `docker compose -f docker-compose.yml up -d` path that doesn't go
# through the installer.

set -euo pipefail

INGRESS_URL="http://127.0.0.1/tax/health"
SINGLE_PORT="${WEB_PUBLISH_PORT:-8082}"
SINGLE_URL="http://127.0.0.1:${SINGLE_PORT}/api/health"

if ! command -v curl >/dev/null 2>&1; then
    echo "healthcheck: curl missing — cannot probe $INGRESS_URL" >&2
    exit 1
fi

probe() {
    local url="$1"
    local response
    response="$(curl -fsS --max-time 5 "$url" 2>&1)" || return 1
    if printf '%s' "$response" | grep -qiE '"(status|ok)"[[:space:]]*:[[:space:]]*"?(ok|true|healthy)"?'; then
        echo "healthcheck: ok ($url)"
        return 0
    fi
    # Some 2xx bodies don't follow the {"status":"ok"} pattern — the
    # api just returning 2xx is good enough.
    echo "healthcheck: ok ($url — non-standard 2xx body)"
    return 0
}

if probe "$INGRESS_URL"; then
    exit 0
fi
if probe "$SINGLE_URL"; then
    exit 0
fi

echo "healthcheck: both $INGRESS_URL and $SINGLE_URL unreachable" >&2
exit 1
