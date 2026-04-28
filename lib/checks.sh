#!/usr/bin/env bash
# `vibe doctor` checks — host prerequisites + per-app container health.
# Each check function: prints a single status line and returns 0 (ok) or non-zero (fail/warn).

# common.sh / config.sh sourced by caller.

_check_pass=0
_check_fail=0
_check_warn=0

_check() {
    local label="$1"; shift
    local status="$1"; shift
    local detail="${*:-}"
    case "$status" in
        ok)   ok   "$(printf '%-32s %s' "$label" "$detail")"; _check_pass=$((_check_pass+1)) ;;
        warn) warn "$(printf '%-32s %s' "$label" "$detail")"; _check_warn=$((_check_warn+1)) ;;
        fail) err  "$(printf '%-32s %s' "$label" "$detail")"; _check_fail=$((_check_fail+1)) ;;
    esac
}

check_os() {
    local id ver
    id="$(os_id)"; ver="$(os_version)"
    if [ "$id" = "ubuntu" ] && [ "$ver" = "24.04" ]; then
        _check "OS" ok "Ubuntu 24.04 LTS"
    elif [ "$id" = "ubuntu" ]; then
        _check "OS" warn "Ubuntu $ver (24.04 LTS recommended)"
    else
        _check "OS" warn "$id $ver (Ubuntu 24.04 LTS recommended)"
    fi
}

check_arch() {
    local a; a="$(arch)"
    case "$a" in
        amd64|arm64) _check "Architecture" ok "$a" ;;
        *)           _check "Architecture" fail "$a (need amd64 or arm64)" ;;
    esac
}

check_ram() {
    local g; g="$(free_mem_gb)"
    if [ "$g" -ge 8 ]; then
        _check "RAM" ok "${g} GB"
    elif [ "$g" -ge 4 ]; then
        _check "RAM" warn "${g} GB (8 GB recommended)"
    else
        _check "RAM" fail "${g} GB (need at least 4 GB)"
    fi
}

check_disk() {
    local g; g="$(free_disk_gb /var)"
    if [ "$g" -ge 40 ]; then
        _check "Disk free (/var)" ok "${g} GB"
    elif [ "$g" -ge 20 ]; then
        _check "Disk free (/var)" warn "${g} GB (40 GB recommended)"
    else
        _check "Disk free (/var)" fail "${g} GB (need at least 20 GB)"
    fi
}

check_docker() {
    if ! has_cmd docker; then
        _check "Docker" fail "not installed"
        return
    fi
    if ! docker info >/dev/null 2>&1; then
        _check "Docker daemon" fail "not reachable (start the service?)"
        return
    fi
    _check "Docker" ok "$(docker --version 2>/dev/null | head -1)"

    if ! docker compose version >/dev/null 2>&1; then
        _check "Docker Compose v2" fail "not available (need 'docker compose')"
    else
        _check "Docker Compose v2" ok "$(docker compose version --short 2>/dev/null)"
    fi
}

check_network() {
    if ! has_cmd docker; then return; fi
    if docker network inspect "$VIBE_NETWORK" >/dev/null 2>&1; then
        _check "Network: $VIBE_NETWORK" ok "present"
    else
        _check "Network: $VIBE_NETWORK" warn "missing (will be created on first multi-app install)"
    fi
}

check_dirs() {
    local d
    for d in "$VIBE_ETC" "$VIBE_DATA" "$VIBE_LOG"; do
        if [ -d "$d" ]; then
            _check "Dir: $d" ok "present"
        else
            _check "Dir: $d" fail "missing"
        fi
    done
}

check_user() {
    if id "$VIBE_USER" >/dev/null 2>&1; then
        _check "User: $VIBE_USER" ok "exists ($(id -u "$VIBE_USER"):$(id -g "$VIBE_USER"))"
    else
        _check "User: $VIBE_USER" fail "missing"
    fi
}

check_config() {
    if [ -f "$VIBE_CONF" ]; then
        local mode count
        mode="$(config_get mode)"
        count="$(config_installed_count)"
        _check "Config: $VIBE_CONF" ok "mode=$mode, ${count} app(s) installed"
    else
        _check "Config: $VIBE_CONF" fail "missing — run install.sh"
    fi
}

check_ghcr() {
    if ! has_cmd curl; then
        _check "GHCR reachability" warn "curl not present, skipped"
        return
    fi
    if curl -fsSI --max-time 5 https://ghcr.io/ >/dev/null 2>&1; then
        _check "GHCR reachability" ok "https://ghcr.io reachable"
    else
        _check "GHCR reachability" warn "https://ghcr.io not reachable (offline?)"
    fi
}

# Per-app HTTP probe. Picks the right URL based on mode:
#   single-app: hits the app's published host port directly.
#   multi-app : hits https://<host>/<app>/health through the Caddy ingress
#               (curl -k tolerates the self-signed cert in `internal` mode).
check_app_http() {
    local app="$1"
    local mode host url
    mode="$(config_get mode)"
    host="$(config_get host)"
    [ -z "$host" ] && host="vibe.local"

    if [ "$mode" = "multi" ]; then
        url="https://${host}/${app}/health"
    else
        case "$app" in
            mybooks)
                local p; p="$(secrets_get mybooks PORT 2>/dev/null || true)"
                url="http://127.0.0.1:${p:-3001}/health"
                ;;
            connect)
                local p; p="$(secrets_get connect APP_PUBLISH_PORT 2>/dev/null || true)"
                url="http://127.0.0.1:${p:-4000}/health"
                ;;
            tb)
                local p; p="$(secrets_get tb WEB_PUBLISH_PORT 2>/dev/null || true)"
                url="http://127.0.0.1:${p:-8081}/api/v1/health"
                ;;
            payroll)
                local p; p="$(secrets_get payroll CADDY_HTTP_PORT 2>/dev/null || true)"
                url="http://127.0.0.1:${p:-80}/api/v1/health"
                ;;
            tax)
                # Tax-chat publishes web on WEB_PUBLISH_PORT (default
                # 8082). The web container's nginx proxies /api/* to
                # the api:4000 service. Health endpoint is /api/health
                # (no /v1 prefix — see apps/api/src/routes/health.ts).
                local p; p="$(secrets_get tax WEB_PUBLISH_PORT 2>/dev/null || true)"
                url="http://127.0.0.1:${p:-8082}/api/health"
                ;;
            *) _check "App: $app" warn "no probe URL registered"; return ;;
        esac
    fi

    if ! has_cmd curl; then
        _check "App: $app" warn "curl missing — skipping HTTP probe"
        return
    fi

    if curl -fsSk --max-time 5 "$url" >/dev/null 2>&1; then
        _check "App: $app" ok "$url"
    else
        # Distinguish "container not running" from "running but unreachable" so
        # the operator knows where to look first.
        local container_count
        container_count="$(apps_compose "$app" ps -q 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
        if [ "$container_count" = "0" ]; then
            _check "App: $app" fail "no containers running — try 'sudo vibe install $app' or 'vibe logs $app'"
        else
            _check "App: $app" fail "$url unreachable (containers running — check 'vibe logs $app')"
        fi
    fi
}

# Probe every installed Vibe app + the ingress (in multi-app mode).
check_apps() {
    local count
    count="$(config_installed_count 2>/dev/null || echo 0)"
    [ "$count" -eq 0 ] && return 0

    local mode
    mode="$(config_get mode)"
    if [ "$mode" = "multi" ] && has_cmd curl; then
        local host
        host="$(config_get host)"
        if curl -fsSk --max-time 5 "https://${host:-vibe.local}/healthz" >/dev/null 2>&1; then
            _check "Ingress" ok "https://${host:-vibe.local}/healthz"
        else
            _check "Ingress" fail "https://${host:-vibe.local}/healthz unreachable"
        fi
    fi

    local app
    while IFS= read -r app; do
        [ -z "$app" ] && continue
        check_app_http "$app"
    done < <(config_installed_list)
}

# Master command — ordered for fail-fast feel.
checks_run_all() {
    _check_pass=0; _check_fail=0; _check_warn=0
    check_os
    check_arch
    check_ram
    check_disk
    check_docker
    check_network
    check_dirs
    check_user
    check_config
    check_ghcr
    check_apps
    echo
    log "summary: ${_check_pass} ok, ${_check_warn} warn, ${_check_fail} fail"
    [ "$_check_fail" -eq 0 ] || return 1
}
