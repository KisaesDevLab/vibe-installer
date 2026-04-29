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
    # In cf-tunnel mode, pull the stashed token from
    # /etc/vibe/cloudflared/tunnel.token so compose can interpolate
    # ${TUNNEL_TOKEN} into the cloudflared sidecar's command. Empty in
    # other modes (the sidecar is profile-gated and never started).
    local tunnel_token=""
    if [ "${tls:-internal}" = "cf-tunnel" ]; then
        local stash="${VIBE_ETC}/cloudflared/tunnel.token"
        if [ -r "$stash" ]; then
            tunnel_token="$(cat "$stash")"
        fi
    fi
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
        printf 'TUNNEL_TOKEN=%s\n'    "${tunnel_token}"
    } > "$env"
    # 0600 — file now contains the cf-tunnel token (when in cf-tunnel mode).
    # Was 0640 before that field existed.
    chmod 0600 "$env"
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

    # Site host list: hostname only, OR `hostname, ip` so Caddy mints an
    # internal cert covering both. Only `internal` mode adds the LAN IP
    # SAN — `acme` can't (Let's Encrypt won't issue for an IP), and
    # `cf-tunnel` doesn't need it (the tunnel only ever sees the hostname).
    local site_hosts="{\$VIBE_HOST}"
    if [ "$tls" = "internal" ] && [ -n "$host_ip" ]; then
        site_hosts="{\$VIBE_HOST}, ${host_ip}"
    fi

    # TLS directive + ACME email line.
    #
    # cf-tunnel inherits `tls internal` from the internal arm: cloudflared
    # connects to caddy:443 with `noTLSVerify: true`, so a self-signed cert
    # at the Caddy layer is fine. This collapses what used to be a third
    # branch (plain HTTP via `http://` scheme prefix) — the source of every
    # cf-tunnel renderer bug shipped in 8589e3c and f790696.
    local tls_directive="" email_line=""
    case "$tls" in
        internal|cf-tunnel)
            tls_directive=$'    tls internal'
            email_line=$'    # tls='"${tls}"$' — no ACME registration'
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

    # Substitute placeholders.
    local out
    out="$(ingress_caddyfile_path)"
    awk -v tls="$tls_directive" -v frags="$fragments" -v eml="$email_line" -v sh="$site_hosts" '
        { gsub(/@@TLS_DIRECTIVE@@/, tls);
          gsub(/@@APP_FRAGMENTS@@/, frags);
          gsub(/@@EMAIL_LINE@@/, eml);
          gsub(/@@SITE_HOSTS@@/, sh);
          print }
    ' "$INGRESS_TEMPLATE" > "$out"
    chmod 0644 "$out"
    chown "$VIBE_USER:$VIBE_USER" "$out"

    # Validate before any caller (ingress_up / ingress_reload) gets a chance
    # to push a busted config into the live container. Both shipped cf-tunnel
    # bugs (auto_https-in-site-block, healthcheck wrong protocol) would have
    # tripped this check.
    ingress_validate_caddyfile "$out"

    # Update the installed-apps JSON the landing page reads.
    ingress_render_installed_json

    ok "ingress: rendered ${out} (host=${host}, tls=${tls})"
}

# Run `caddy validate` against a rendered Caddyfile. Prefers a host-installed
# `caddy` binary (fast) and falls back to a one-shot `caddy:2-alpine` docker
# run (works on any host with docker). Returns 0 on a valid config and dies
# on an invalid one — callers should not catch the exit; bailing is the
# point of validation.
#
# VIBE_HOST is exported into the validator's env because Caddyfile.template
# references it via `{$VIBE_HOST}`. With it unset, the substitution yields
# the empty string, which makes Caddy parse the site block as a second
# global block and bail with "server block without any key is global
# configuration". Other vars (TLS_MODE, ACME_EMAIL) are read by lib/ingress.sh
# during render and don't survive into the rendered file as `{$NAME}`
# substitutions, so they don't need to be in the validator env.
ingress_validate_caddyfile() {
    local file="${1:?usage: ingress_validate_caddyfile <path>}"
    local host
    host="$(config_get host 2>/dev/null || true)"
    [ -z "$host" ] && host="vibe.local"
    if has_cmd caddy; then
        if ! VIBE_HOST="$host" caddy validate --config "$file" --adapter caddyfile >/dev/null 2>&1; then
            err "rendered Caddyfile failed validation:"
            VIBE_HOST="$host" caddy validate --config "$file" --adapter caddyfile >&2 || true
            die "refusing to apply invalid Caddyfile (${file})"
        fi
    elif has_cmd docker; then
        if ! docker run --rm -i -e "VIBE_HOST=${host}" caddy:2-alpine \
                caddy validate --config /dev/stdin --adapter caddyfile <"$file" >/dev/null 2>&1; then
            err "rendered Caddyfile failed validation:"
            docker run --rm -i -e "VIBE_HOST=${host}" caddy:2-alpine \
                caddy validate --config /dev/stdin --adapter caddyfile <"$file" >&2 || true
            die "refusing to apply invalid Caddyfile (${file})"
        fi
    else
        warn "ingress: neither 'caddy' nor 'docker' available — skipping Caddyfile validation"
        return 0
    fi
    dbg "ingress: ${file} passed caddy validate"
}

# Render to a tmp dir + validate without touching the live config. Used by
# `vibe ingress preview` so an operator can sanity-check changes before
# reloading the running container.
ingress_preview_caddyfile() {
    require_root
    local tmp_etc tmp_file saved_etc
    tmp_etc="$(mktemp -d)"
    saved_etc="$INGRESS_ETC"
    # Restore INGRESS_ETC + clean up tmp dir on every exit path — render
    # may `die`, in which case we'd otherwise leak a redirected global.
    trap 'INGRESS_ETC="'"$saved_etc"'"; rm -rf "'"$tmp_etc"'"; trap - RETURN' RETURN

    INGRESS_ETC="$tmp_etc"
    ingress_render_caddyfile
    tmp_file="$(ingress_caddyfile_path)"

    echo
    log "rendered Caddyfile (preview only — live config untouched):"
    echo
    cat "$tmp_file"
    echo
    ok "preview validated"
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
# In cf-tunnel mode, `--profile tunnel` is auto-prepended so the cloudflared
# sidecar (defined in ingress/docker-compose.yml under `profiles: [tunnel]`)
# gets brought up alongside Caddy. Other modes leave the profile inactive
# and the sidecar stays down — single source of truth: vibe.conf.
ingress_compose() {
    local env tls
    env="$(ingress_envfile_path)"
    tls="$(config_get tls_mode 2>/dev/null || true)"
    local profile_args=()
    if [ "$tls" = "cf-tunnel" ]; then
        profile_args=(--profile tunnel)
    fi
    docker compose --project-name "$INGRESS_PROJECT" \
                   --env-file "$env" \
                   "${profile_args[@]}" \
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
