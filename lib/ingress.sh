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
ingress_caddyfile_path()      { printf '%s/Caddyfile\n' "$INGRESS_ETC"; }
ingress_envfile_path()        { printf '%s/.env\n'      "$INGRESS_ETC"; }
ingress_landing_dir()         { printf '%s/ingress/landing\n' "$VIBE_PREFIX"; }
ingress_installed_json()      { printf '%s/__vibe_installed.json\n'      "$(ingress_landing_dir)"; }
ingress_appliance_json()      { printf '%s/__vibe_appliance.json\n'      "$(ingress_landing_dir)"; }
ingress_upgrade_check_json()  { printf '%s/__vibe_upgrade_check.json\n'  "$(ingress_landing_dir)"; }

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

    # 2. Concatenate per-app fragments from config_installed_list — what
    # `vibe install` added. The admin SPA's caddy.fragment used to be
    # always-included here pre-2026-04; it was dropped along with the
    # whole admin stack (replaced by the static operator panel on the
    # landing page).
    local fragments="" frag app
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

    # Update the JSON feeds the landing page reads. Both are cheap +
    # idempotent; no reason not to refresh on every Caddyfile render.
    ingress_render_installed_json
    ingress_render_appliance_json

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

# JSON consumed by the landing page's operator panel. Carries the SSH
# connection bits + version metadata so the panel can render
# copy-pasteable commands like `ssh ${ssh_user}@${host}` without the
# operator having to remember them.
#
# ssh_user comes from vibe.conf when set (install.sh writes it from
# ${SUDO_USER:-$(logname)} during render_config). Falls back to
# $SUDO_USER, then to "vibe" — last-resort default that matches the
# system user the installer creates anyway, so the snippet is at worst
# a useful starting point.
ingress_render_appliance_json() {
    local out
    out="$(ingress_appliance_json)"
    local host host_ip tls ssh_user vibe_version
    host="$(config_get host)"
    [ -z "$host" ] && host="vibe.local"
    host_ip="$(config_get host_ip)"
    tls="$(config_get tls_mode)"
    [ -z "$tls" ] && tls="internal"
    ssh_user="$(config_get ssh_user)"
    [ -z "$ssh_user" ] && ssh_user="${SUDO_USER:-vibe}"
    # Pull from bin/vibe so we don't drift from the CLI's reported version.
    # `vibe version` is the simplest path; falls back to grepping the script
    # if the binary isn't on PATH yet (mid-install).
    if has_cmd vibe; then
        vibe_version="$(vibe version 2>/dev/null || true)"
    fi
    if [ -z "$vibe_version" ] && [ -f "${VIBE_PREFIX}/bin/vibe" ]; then
        vibe_version="$(grep -E '^VIBE_VERSION=' "${VIBE_PREFIX}/bin/vibe" | head -1 | cut -d'"' -f2)"
    fi
    [ -z "$vibe_version" ] && vibe_version="unknown"

    printf '{"host":"%s","host_ip":"%s","ssh_user":"%s","vibe_version":"%s","tls_mode":"%s","generated":%s}\n' \
        "$host" "$host_ip" "$ssh_user" "$vibe_version" "$tls" "$(date +%s)" > "$out"
    chmod 0644 "$out"
}

# Refresh /__vibe_upgrade_check.json from `vibe upgrade-check --json`.
# Wraps the CLI output with two top-level fields the SPA needs:
#
#   checked_at       — Unix ts of THIS run, regardless of success
#   last_success_at  — Unix ts of the last fully-successful check
#
# When the current check fails (no GHCR connectivity, malformed output,
# all per-app entries reporting `offline`/`no-ghcr`), the wrapper
# preserves the previous `apps[]` array and updates only `checked_at`.
# Landing page reads `last_success_at` to render "(check failed; last
# good data N hours old)" inline. Failures never wipe the previous
# good snapshot.
ingress_refresh_upgrade_check() {
    require_root
    local out tmp now prev raw apps_json="" success=0
    out="$(ingress_upgrade_check_json)"
    tmp="$(mktemp)"
    now="$(date +%s)"

    # Best-effort call. Don't `die` on failure — we want to be able to
    # update only the timestamp.
    raw="$("${VIBE_PREFIX}/bin/vibe" upgrade-check --json 2>/dev/null || true)"
    if [ -n "$raw" ] && printf '%s' "$raw" | grep -q '"apps":\['; then
        # Strip the closing `}` so we can append our two timestamp
        # fields without parsing/re-serializing JSON. The input is
        # `{"apps":[...]}` with no whitespace (per update_check.sh).
        apps_json="$(printf '%s' "$raw" | sed -E 's/}$//')"

        # "success" means at least one app entry has a non-failure
        # status. If every entry is offline/no-ghcr the operator gets
        # nothing useful from THIS run; treat it as a failure so we
        # don't overwrite a previous good snapshot.
        if printf '%s' "$raw" | grep -qE '"status":"(current|outdated|unpinned|ahead|no-tags)"'; then
            success=1
        fi
    fi

    if [ "$success" -eq 1 ]; then
        printf '%s,"checked_at":%s,"last_success_at":%s}\n' \
            "$apps_json" "$now" "$now" > "$tmp"
    else
        # Preserve the previous apps[] + last_success_at. If there's no
        # previous file at all (first run, GHCR unreachable), emit an
        # empty apps[] and last_success_at=0 so the SPA can render
        # "no successful check yet".
        local prev_apps='"apps":[]' prev_success=0
        if [ -f "$out" ]; then
            prev="$(cat "$out")"
            local extracted
            extracted="$(printf '%s' "$prev" | grep -oE '"apps":\[[^]]*\]' | head -1)"
            [ -n "$extracted" ] && prev_apps="$extracted"
            local extracted_ts
            extracted_ts="$(printf '%s' "$prev" | grep -oE '"last_success_at":[0-9]+' | head -1 | cut -d: -f2)"
            [ -n "$extracted_ts" ] && prev_success="$extracted_ts"
        fi
        printf '{%s,"checked_at":%s,"last_success_at":%s}\n' \
            "$prev_apps" "$now" "$prev_success" > "$tmp"
    fi

    install -m 0644 "$tmp" "$out"
    rm -f "$tmp"
    if [ "$success" -eq 1 ]; then
        ok "ingress: upgrade-check refreshed ($out)"
    else
        warn "ingress: upgrade-check failed (offline / no-ghcr) — preserved previous data"
    fi
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
