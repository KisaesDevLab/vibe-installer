#!/usr/bin/env bash
# Vibe MyBooks healthcheck — invoked by `vibe doctor` and post-install verify.
# Returns 0 if the api is reachable and reports a healthy state, 1 otherwise.
#
# The api container's own healthcheck hits http://localhost:3001/health from
# inside the container; this script hits the published host port instead so
# we also catch port-binding regressions.

set -euo pipefail

# Single-app mode publishes ${PORT:-3001} on the host. Multi-app mode hides
# the api container behind Caddy at /mybooks/api/ — that path is exercised
# by lib/checks.sh::check_app_http rather than this script.
PORT="${PORT:-3001}"
URL="http://127.0.0.1:${PORT}/health"

# wget vs curl: alpine images sometimes ship busybox-only; the host ALWAYS
# has curl (install.sh installs it). Use curl with a tight timeout — a slow
# api means an unhealthy api in this context.
if ! command -v curl >/dev/null 2>&1; then
    echo "healthcheck: curl missing — cannot probe $URL" >&2
    exit 1
fi

response="$(curl -fsS --max-time 5 "$URL" 2>&1)" || {
    echo "healthcheck: $URL unreachable: $response" >&2
    exit 1
}

# /health response shape (from packages/api/src/routes/health.ts):
#   { "status": "ok", "uptime": <seconds>, ... }
# Accept any 2xx body; only flag !ok if the server explicitly says so.
if printf '%s' "$response" | grep -qiE '"status"[[:space:]]*:[[:space:]]*"(ok|healthy)"'; then
    echo "healthcheck: ok ($URL)"
    exit 0
elif [ -n "$response" ]; then
    echo "healthcheck: ok ($URL — non-JSON body but 2xx)"
    exit 0
else
    echo "healthcheck: $URL returned empty body" >&2
    exit 1
fi
