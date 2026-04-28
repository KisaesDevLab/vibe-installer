#!/usr/bin/env bash
# Admin tools — Portainer + Duplicati.
#
# Both services bind 127.0.0.1 only and run on a separate `vibe_admin`
# Docker network so the Caddy ingress can't accidentally expose them.
# Operators reach them via Tailscale `ssh -L 9443:127.0.0.1:9443` or by
# browsing from the LAN if SSH access is configured.
#
# common.sh + secrets.sh sourced by callers.

TOOLS_PROJECT="${TOOLS_PROJECT:-vibe-tools}"
TOOLS_COMPOSE="${VIBE_PREFIX}/tools/docker-compose.yml"
TOOLS_ETC="${VIBE_ETC}/tools"

tools_compose() {
    docker compose --project-name "$TOOLS_PROJECT" \
                   --env-file "${TOOLS_ETC}/.env" \
                   -f "$TOOLS_COMPOSE" "$@"
}

tools_install() {
    require_root

    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" \
        "${VIBE_DATA}/tools/portainer" \
        "${VIBE_DATA}/tools/duplicati" \
        "${VIBE_DATA}/tools/backups"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$TOOLS_ETC"

    # Per-tool secrets file. Duplicati needs SETTINGS_ENCRYPTION_KEY to
    # encrypt its config DB; Portainer's admin password is set on first
    # login through the UI (Portainer doesn't accept env-baked passwords
    # in CE without the --admin-password-file workaround, which adds more
    # complexity than it's worth for a 127.0.0.1-only service).
    if [ ! -f "${TOOLS_ETC}/.env" ]; then
        local dup_key tz vuid vgid
        dup_key="$(secrets_hex32)"
        tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
        # Duplicati needs PUID/PGID matching vibe so it can read
        # /var/lib/vibe/<app>/* (mode 0750, owned by vibe).
        vuid="$(id -u "$VIBE_USER" 2>/dev/null || echo 1000)"
        vgid="$(id -g "$VIBE_USER" 2>/dev/null || echo 1000)"
        cat > "${TOOLS_ETC}/.env" <<EOF
DUPLICATI_SETTINGS_KEY=${dup_key}
TZ=${tz}
VIBE_UID=${vuid}
VIBE_GID=${vgid}
EOF
        chown "$VIBE_USER:$VIBE_USER" "${TOOLS_ETC}/.env"
        chmod 0600 "${TOOLS_ETC}/.env"
        ok "wrote ${TOOLS_ETC}/.env (mode 0600, PUID=${vuid} PGID=${vgid})"
    fi

    log "starting Portainer + Duplicati..."
    tools_compose pull --quiet || true
    tools_compose up -d --remove-orphans

    local host
    host="$(config_get host 2>/dev/null || echo vibe.local)"
    [ -z "$host" ] && host="vibe.local"

    ok "Admin tools are up."
    cat <<EOM

    Portainer (Docker UI): https://127.0.0.1:9443/
        First login asks you to set the admin password.
        TLS cert is self-signed — accept the warning.

    Duplicati (backups):   http://127.0.0.1:8200/
        Reaches /var/lib/vibe/ read-only at /source for backup jobs.
        Drops backup outputs at /backups (host: /var/lib/vibe/tools/backups/).

  Both services bind to 127.0.0.1 only. Reach them from elsewhere via:
    ssh -L 9443:127.0.0.1:9443 <user>@${host}    # Portainer
    ssh -L 8200:127.0.0.1:8200 <user>@${host}    # Duplicati
  ...or via Tailscale once 'vibe install tailscale' is done.

EOM
}

tools_uninstall() {
    require_root
    log "stopping admin tools..."
    tools_compose down --remove-orphans
    if confirm "Remove tools data at ${VIBE_DATA}/tools/? (Portainer config, Duplicati state) [y/N] " no; then
        rm -rf "${VIBE_DATA}/tools"
        ok "tools data removed"
    else
        ok "tools data preserved at ${VIBE_DATA}/tools/"
    fi
    if [ -f "${TOOLS_ETC}/.env" ]; then
        rm -f "${TOOLS_ETC}/.env"
    fi
}

tools_status() {
    if docker ps --filter 'name=^vibe-tools-' --format '{{.Names}}\t{{.Status}}' 2>/dev/null \
        | grep -q vibe-tools-; then
        log "Admin tools status:"
        docker ps --filter 'name=^vibe-tools-' --format '  {{.Names}}\t{{.Status}}'
    else
        warn "Admin tools not running (sudo vibe install tools)"
    fi
}
