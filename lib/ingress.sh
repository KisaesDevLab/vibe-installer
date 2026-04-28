#!/usr/bin/env bash
# Caddy ingress lifecycle + Caddyfile rendering.
#
# State on disk:
#   /etc/vibe/ingress/Caddyfile         rendered config (bind-mounted into caddy)
#   /etc/vibe/ingress/.env              VIBE_HOST/TLS_MODE/ACME_EMAIL for compose
#   /var/lib/vibe/ingress/data/         caddy ACME state (account keys, certs)
#   /var/lib/vibe/ingress/config/       caddy auto-saved config
#   /opt/vibe-installer/ingress/landing/__vibe_installed.json   installed-apps registry
#
# common.sh + config.sh sourced by callers.

INGRESS_PROJECT="${INGRESS_PROJECT:-vibe-ingress}"
INGRESS_ETC="${VIBE_ETC}/ingress"
INGRESS_DATA="${VIBE_DATA}/ingress"
INGRESS_COMPOSE="${VIBE_PREFIX}/ingress/docker-compose.yml"
INGRESS_TEMPLATE="${VIBE_PREFIX}/ingress/Caddyfile.template"

# ---------- Path helpers ----------
ingress_caddyfile_path() { printf '%s/Caddyfile\n' "$INGRESS_ETC"; }
ingress_envfile_path()   { printf '%s/.env\n'      "$INGRESS_ETC"; }
ingress_installed_json() { printf '%s/ingress/landing/__vibe_installed.json\n' "$VIBE_PREFIX"; }

# ---------- Directory + env file setup ----------
ingress_ensure_dirs() {
    require_root
    install -d -m 0755 -o "$VIBE_USER" -g "$VIBE_USER" "$INGRESS_ETC"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$INGRESS_DATA"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$INGRESS_DATA/data"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$INGRESS_DATA/config"
}

ingress_render_envfile() {
    require_root
    # Ensure /etc/vibe/ingress/ exists before redirecting `> "$env"` into it.
    # ingress_render_caddyfile also calls this, but envfile rendering happens
    # first in ingress_up — so without an explicit call here the redirect
    # fails with "No such file or directory".
    ingress_ensure_dirs
    local env
    env="$(ingress_envfile_path)"
    local host host_ip tls email
    host="$(config_get host)"
    host_ip="$(config_get host_ip)"
    tls="$(config_get tls_mode)"
    # ACME contact email: vibe.conf (set by install.sh's intent prompts) is
    # the source of truth. Fall back to the legacy env-var precedence so
    # unattended installs that set VIBE_ACME_EMAIL/ACME_EMAIL keep working.
    email="$(config_get acme_email)"
    [ -z "$email" ] && email="${VIBE_ACME_EMAIL:-${ACME_EMAIL:-}}"
    {
        printf 'VIBE_HOST=%s\n'       "${host:-vibe.local}"
        # IP gets baked into the cert as a SAN (see ingress_render_caddyfile)
        # so https://<ip>/ works alongside https://<host>/.
        printf 'VIBE_HOST_IP=%s\n'    "${host_ip}"
        printf 'TLS_MODE=%s\n'        "${tls:-internal}"
        printf 'VIBE_PREFIX=%s\n'     "$VIBE_PREFIX"
        printf 'INGRESS_HTTP_PORT=%s\n'  "${INGRESS_HTTP_PORT:-80}"
        printf 'INGRESS_HTTPS_PORT=%s\n' "${INGRESS_HTTPS_PORT:-443}"
        printf 'ACME_EMAIL=%s\n'      "${email}"
    } > "$env"
    chmod 0640 "$env"
    chown "$VIBE_USER:$VIBE_USER" "$env"
}

# ---------- Caddyfile rendering ----------
# Reads vibe.conf for host + tls_mode + installed list, walks the installed
# apps in order, concatenates each apps/<app>/caddy.fragment, and substitutes
# the placeholders in ingress/Caddyfile.template.
ingress_render_caddyfile() {
    require_root
    ingress_ensure_dirs
    [ -f "$INGRESS_TEMPLATE" ] || die "ingress template missing: $INGRESS_TEMPLATE"

    local host host_ip tls
    host="$(config_get host)"
    host_ip="$(config_get host_ip)"
    tls="$(config_get tls_mode)"
    [ -n "$host" ] || die "host not set in $VIBE_CONF (rerun install.sh)"

    # 0. Build the site host list: hostname only, OR `hostname, ip` so
    #    Caddy mints an internal cert covering both. ACME and cf-tunnel
    #    skip the IP — Let's Encrypt won't issue for an IP, and a
    #    cf-tunnel target hostname is the only thing the tunnel routes
    #    to anyway. The placeholder is replaced via awk; Caddy's own
    #    {$VIBE_HOST} substitution still works for the hostname leg.
    local site_hosts="{\$VIBE_HOST}"
    if [ "$tls" = "internal" ] && [ -n "$host_ip" ]; then
        site_hosts="{\$VIBE_HOST}, ${host_ip}"
    fi

    # 1. Build the @@TLS_DIRECTIVE@@ + @@EMAIL_LINE@@ blocks.
    local tls_directive="" email_line=""
    case "$tls" in
        internal)
            tls_directive=$'    tls internal'
            # No ACME, no email needed.
            email_line=$'    # tls=internal — no ACME registration'
            ;;
        acme)
            # Caddy with global `email` directive handles HTTP-01 automatically.
            tls_directive=""
            # acme_email in vibe.conf (set by install.sh's intent prompts)
            # is the source of truth. The legacy env-var precedence still
            # works for unattended installs that set VIBE_ACME_EMAIL.
            local em
            em="$(config_get acme_email)"
            [ -z "$em" ] && em="${VIBE_ACME_EMAIL:-${ACME_EMAIL:-}}"
            if [ -n "$em" ]; then
                email_line="    email ${em}"
            else
                # No email provided — Caddy will still register with ACME but
                # without an account email (works, but renewal warnings won't
                # be deliverable).
                email_line=$'    # tls=acme but no acme_email set; renewal alerts disabled'
            fi
            ;;
        cf-tunnel)
            # No TLS at the Caddy layer; cloudflared terminates upstream.
            tls_directive=$'    auto_https off'
            email_line=$'    # tls=cf-tunnel — Cloudflare terminates TLS'
            ;;
        *) die "unknown tls_mode: $tls (expected internal|acme|cf-tunnel)" ;;
    esac

    # 2. Concatenate per-app fragments. Two sources:
    #    - The system admin app (apps/admin/) — always included if the
    #      fragment exists. install.sh drops the admin stack alongside
    #      the ingress; it isn't part of the user-driven `installed=`
    #      list because it isn't optional.
    #    - User apps from config_installed_list — what `vibe install`
    #      added.
    local fragments="" frag app
    local admin_frag="${VIBE_PREFIX}/apps/admin/caddy.fragment"
    if [ -f "$admin_frag" ]; then
        fragments+=$'\n    # ---- admin (system) ----\n'
        fragments+="$(sed 's/^/    /' "$admin_frag")"
        fragments+=$'\n'
    fi
    for app in $(config_installed_list); do
        frag="${VIBE_PREFIX}/apps/${app}/caddy.fragment"
        if [ -f "$frag" ]; then
            fragments+=$'\n    # ---- '"$app"' ----\n'
            # Indent each line by 4 spaces to match the surrounding handle blocks.
            fragments+="$(sed 's/^/    /' "$frag")"
            fragments+=$'\n'
        else
            warn "ingress: $app installed but no caddy.fragment at $frag"
        fi
    done

    # 3. The cf-tunnel mode is served by the same `${VIBE_HOST}` block above
    #    — `auto_https off` makes Caddy listen on plain :80 only, which is
    #    exactly what cloudflared connects to. No second site block needed.
    local cf_block=""

    # 4. Substitute placeholders.
    local out
    out="$(ingress_caddyfile_path)"
    awk -v tls="$tls_directive" -v frags="$fragments" -v cfb="$cf_block" -v eml="$email_line" -v sh="$site_hosts" '
        { gsub(/@@TLS_DIRECTIVE@@/, tls);
          gsub(/@@APP_FRAGMENTS@@/, frags);
          gsub(/@@CF_TUNNEL_BLOCK@@/, cfb);
          gsub(/@@EMAIL_LINE@@/, eml);
          gsub(/@@SITE_HOSTS@@/, sh);
          print }
    ' "$INGRESS_TEMPLATE" > "$out"
    chmod 0644 "$out"
    chown "$VIBE_USER:$VIBE_USER" "$out"

    # 5. Update the installed-apps JSON the landing page reads.
    ingress_render_installed_json

    ok "ingress: rendered ${out} (host=${host}, tls=${tls})"
}

# Tiny JSON the landing page fetches to hide tiles for uninstalled apps.
# Hand-built (no jq dependency) — the data is a known-shape list of short ids.
ingress_render_installed_json() {
    local out
    out="$(ingress_installed_json)"
    local apps_csv apps_json="["
    apps_csv="$(config_get installed)"
    if [ -n "$apps_csv" ]; then
        local app first=1
        while IFS= read -r app; do
            [ -z "$app" ] && continue
            # Validate against the registry — refuse to emit unknown ids into JSON.
            apps_is_supported "$app" || continue
            if [ $first -eq 1 ]; then first=0; else apps_json+=","; fi
            apps_json+="\"${app}\""
        done < <(printf '%s\n' "$apps_csv" | tr ',' '\n')
    fi
    apps_json+="]"
    printf '{"apps":%s,"generated":%s}\n' "$apps_json" "$(date +%s)" > "$out"
    chmod 0644 "$out"
}

# ---------- Compose lifecycle ----------
ingress_compose() {
    local env
    env="$(ingress_envfile_path)"
    docker compose --project-name "$INGRESS_PROJECT" \
                   --env-file "$env" \
                   -f "$INGRESS_COMPOSE" "$@"
}

ingress_up() {
    require_root
    ingress_render_envfile
    ingress_render_caddyfile
    log "starting Caddy ingress..."
    ingress_compose up -d --remove-orphans
    ok "ingress up"
}

# Apply a rendered Caddyfile to a running ingress without recreating the
# container. Caddy responds to SIGHUP by reloading config gracefully.
ingress_reload() {
    if ! ingress_running; then
        warn "ingress not running — bringing up instead of reload"
        ingress_up
        return
    fi
    ingress_render_caddyfile
    log "reloading Caddy (SIGHUP)..."
    docker kill --signal=HUP vibe-ingress-caddy >/dev/null
    ok "ingress reloaded"
}

ingress_down() {
    if ! ingress_running; then
        ok "ingress already down"
        return 0
    fi
    log "stopping Caddy ingress..."
    ingress_compose down --remove-orphans
    ok "ingress down"
}

ingress_running() {
    docker ps --filter 'name=^vibe-ingress-caddy$' --format '{{.Names}}' 2>/dev/null \
        | grep -qx vibe-ingress-caddy
}

# ---------- caddy trust ----------
# In `internal` TLS mode the host needs Caddy's CA root in its trust store
# so `curl https://vibe.local/...` works without -k. We ask the running
# container to install its root into /etc/ssl/certs on the host.
ingress_trust_local_ca() {
    if [ "$(config_get tls_mode)" != "internal" ]; then
        dbg "trust: tls_mode != internal, skipping caddy trust"
        return 0
    fi
    if ! has_cmd update-ca-certificates; then
        warn "trust: update-ca-certificates missing — install ca-certificates and re-run 'vibe doctor'"
        return 0
    fi
    if ! ingress_running; then
        warn "trust: ingress not running — start it before trusting the CA"
        return 0
    fi

    log "waiting for Caddy to generate its local CA..."
    # Caddy generates root.crt lazily — on the first TLS handshake. Trigger
    # a handshake (curl -k against ourselves) and poll for up to 30 seconds.
    local deadline=$(( $(date +%s) + 30 )) seen_root=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if docker exec vibe-ingress-caddy test -s /data/caddy/pki/authorities/local/root.crt 2>/dev/null; then
            seen_root=1
            break
        fi
        # Poke the local TLS port to force the cert pipeline.
        curl -ks --max-time 2 https://127.0.0.1/ >/dev/null 2>&1 || true
        sleep 2
    done

    if [ "$seen_root" -ne 1 ]; then
        warn "trust: Caddy did not generate /data/caddy/pki/authorities/local/root.crt after 30s"
        warn "trust: re-run 'sudo vibe mode multi' once Caddy has served at least one TLS request"
        return 0
    fi

    log "installing Caddy local CA into the host trust store..."
    local root_crt
    root_crt="$(mktemp)"
    if docker exec vibe-ingress-caddy cat /data/caddy/pki/authorities/local/root.crt > "$root_crt" 2>/dev/null; then
        install -m 0644 "$root_crt" /usr/local/share/ca-certificates/vibe-caddy-local.crt
        update-ca-certificates >/dev/null
        ok "trust: Caddy local CA installed in host trust store"
    else
        warn "trust: docker exec cat root.crt failed unexpectedly"
    fi
    rm -f "$root_crt"
}
