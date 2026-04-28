#!/usr/bin/env bash
# End-to-end smoke test for vibe-installer on a fresh Ubuntu 24.04 droplet.
#
# Designed to run in two contexts:
#   1. CI (.github/workflows/droplet-smoke.yml): provisions a DO droplet,
#      copies this script over, runs it, tears the droplet down.
#   2. Manual: SSH into a fresh droplet, copy this script, run it as root.
#
# Required env (script bails if missing):
#   VIBE_HOST                 hostname this droplet will answer to
#   VIBE_TLS_MODE             internal | acme | cf-tunnel
#   VIBE_LICENSE_TOKEN_*      one per app to be tested unattended
#
# Optional:
#   VIBE_SMOKE_APPS           default 'mybooks connect tb' (payroll gated on P-A)
#   VIBE_INSTALLER_REF        default 'main'
#   CF_TUNNEL_TOKEN_MYBOOKS   if set, exercise cloudflare attach/detach for mybooks
#   TS_AUTHKEY                if set, exercise tailscale enrollment
#
# Exit code: 0 = all green; non-zero = something failed (with last failure
# step + container logs printed for triage).

set -euo pipefail

VIBE_HOST="${VIBE_HOST:?set VIBE_HOST}"
VIBE_TLS_MODE="${VIBE_TLS_MODE:-internal}"
VIBE_INSTALLER_REF="${VIBE_INSTALLER_REF:-main}"
VIBE_SMOKE_APPS="${VIBE_SMOKE_APPS:-mybooks connect tb}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

step() { printf '\n=== [smoke] %s ===\n' "$*"; }
fail() { echo "[smoke] FAIL: $*" >&2; exit 1; }

# ---------- 0. Bootstrap ----------
# Under always-multi-app (Phase 1.2 of the Rung-1 build plan), install.sh
# brings up the Caddy ingress at :80/:443 immediately — even before any
# app has been installed. The first thing we verify here is that the
# landing page is reachable straight after install.sh finishes.
step "bootstrap"
export VIBE_HOST VIBE_TLS_MODE VIBE_ASSUME_YES=1
curl -fsSL "https://raw.githubusercontent.com/KisaesDevLab/vibe-installer/${VIBE_INSTALLER_REF}/install.sh" \
    | bash
command -v vibe >/dev/null || fail "vibe symlink missing"
vibe doctor || fail "vibe doctor failed"

# Ingress is up from the moment install.sh exits.
curl -fsSk "https://${VIBE_HOST}/healthz" >/dev/null \
    || fail "ingress /healthz unreachable directly after bootstrap"
vibe mode | grep -q multi || fail "expected mode=multi after bootstrap"

# ---------- 1. First app: lands behind the ingress immediately ----------
first_app="${VIBE_SMOKE_APPS%% *}"
step "install $first_app (multi-app, via ingress)"
vibe install "$first_app" || fail "install $first_app"

# Always-multi: every install lands at https://<host>/<app>/, no per-port
# URLs to probe. Mode stays 'multi' regardless of how many apps install.
vibe status | tee /dev/stderr | grep -q "mode=multi" \
    || fail "expected mode=multi after first install"

curl -fsSk "https://${VIBE_HOST}/${first_app}/health" >/dev/null \
    || fail "/${first_app}/health unreachable through ingress"

# Mode 0600 on env file.
test "$(stat -c %a /etc/vibe/${first_app}/.env)" = 600 \
    || fail "/etc/vibe/${first_app}/.env not 0600"

# ---------- 2. Add the next app — no mode flip, no URL change ----------
remaining_apps="${VIBE_SMOKE_APPS#"$first_app "}"
[ "$remaining_apps" = "$VIBE_SMOKE_APPS" ] && remaining_apps=""

if [ -n "$remaining_apps" ]; then
    next_app="${remaining_apps%% *}"
    step "install $next_app (mode stays multi, $first_app URL unchanged)"
    vibe install "$next_app" || fail "install $next_app"

    vibe mode | grep -q multi || fail "expected mode=multi (didn't flip on second install)"

    # Landing page + per-app tile JSON list both apps.
    curl -fsSk "https://${VIBE_HOST}/" >/dev/null || fail "ingress landing page unreachable"
    installed_json="$(curl -fsSk "https://${VIBE_HOST}/__vibe_installed.json")" \
        || fail "installed.json unreachable"
    echo "$installed_json" | grep -q "\"$first_app\"" || fail "$first_app missing from installed.json"
    echo "$installed_json" | grep -q "\"$next_app\""  || fail "$next_app missing from installed.json"

    # Per-app health behind the ingress.
    curl -fsSk "https://${VIBE_HOST}/${first_app}/health" >/dev/null \
        || fail "/${first_app}/health unreachable through ingress"
    curl -fsSk "https://${VIBE_HOST}/${next_app}/health" >/dev/null \
        || fail "/${next_app}/health unreachable through ingress"
fi

# ---------- 3. All remaining apps ----------
step "install remaining apps"
for app in $VIBE_SMOKE_APPS; do
    vibe status | grep -q "^  $app " && continue
    vibe install "$app" || fail "install $app"
    curl -fsSk "https://${VIBE_HOST}/${app}/health" >/dev/null \
        || fail "/${app}/health unreachable after install"
done

# ---------- 4. DB isolation ----------
step "verify DB isolation"
for app in $VIBE_SMOKE_APPS; do
    container=""
    case "$app" in
        mybooks) container=vibe-mybooks-db-1 ;;
        connect) container=vibe-connect-postgres-1 ;;
        tb)      container=vibe-tb-db-1 ;;
        payroll) container=vibept-postgres ;;
    esac
    docker ps --filter "name=^${container}$" --format '{{.Names}}' | grep -q . \
        || fail "expected DB container $container running"
done

# ---------- 5. Cloudflare attach/detach (optional) ----------
if [ -n "${CF_TUNNEL_TOKEN_MYBOOKS:-}" ] && echo "$VIBE_SMOKE_APPS" | grep -qw mybooks; then
    step "cloudflare attach mybooks"
    vibe cloudflare attach mybooks --token "$CF_TUNNEL_TOKEN_MYBOOKS" || fail "cf attach failed"
    docker ps --filter 'name=mybooks-cloudflared' --format '{{.Names}}' | grep -q . \
        || fail "cloudflared sidecar not running"
    vibe cloudflare detach mybooks || fail "cf detach failed"
    docker ps --filter 'name=mybooks-cloudflared' --format '{{.Names}}' | grep -q . \
        && fail "cloudflared sidecar still running after detach"
fi

# ---------- 6. Tailscale (optional) ----------
if [ -n "${TS_AUTHKEY:-}" ]; then
    step "tailscale enroll"
    TAILSCALE_AUTHKEY="$TS_AUTHKEY" vibe install tailscale || fail "tailscale install"
    tailscale ip -4 >/dev/null || fail "tailscale not up"
fi

# ---------- 7. Tools (LAN-only) ----------
step "install admin tools"
vibe install tools || fail "tools install"
ss -tlnp 2>/dev/null | grep -E ':(9443|8200)' | grep -qE '127\.0\.0\.1' \
    || fail "tools port not bound to 127.0.0.1"

# ---------- 8. upgrade-check is read-only ----------
step "upgrade-check is read-only"
vibe upgrade-check || true   # may report 'newer available' or 'up to date'; either is fine

# ---------- 9. Uninstall everything — mode stays multi, ingress stays up ----------
step "uninstall everything (mode stays multi)"
# Always-multi: removing apps never demotes to single; the ingress keeps
# running on :80/:443 with the landing page so the appliance stays
# reachable for re-installs.
for app in $VIBE_SMOKE_APPS; do
    [ "$app" = "$first_app" ] && continue
    vibe uninstall "$app" || fail "uninstall $app"
done

vibe mode | grep -q multi || fail "expected mode=multi after partial uninstall"
vibe uninstall "$first_app" || fail "uninstall $first_app"

vibe status | grep -q "no apps installed" || fail "expected zero apps after final uninstall"
vibe mode | grep -q multi || fail "expected mode=multi to persist with zero apps"
curl -fsSk "https://${VIBE_HOST}/healthz" >/dev/null \
    || fail "ingress /healthz unreachable after final uninstall"

step "smoke test passed"
