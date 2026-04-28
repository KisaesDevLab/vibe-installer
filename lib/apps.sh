#!/usr/bin/env bash
# Per-app lifecycle — install / upgrade / uninstall / status.
#
# PR2 scope: single-app install for `mybooks`. Multi-app promotion lives in
# lib/mode.sh + lib/ingress.sh (PR3); upgrade/uninstall lifecycle in PR5.
# Stub branches for the other apps land in PR3/PR4.
#
# common.sh + config.sh + secrets.sh + license.sh sourced by callers.

# ---------- Registry of supported apps ----------
# Vibe apps (count toward installed= in vibe.conf, drive mode switching).
APPS_SUPPORTED="mybooks connect tb payroll tax"
# Optional integrations (`vibe install <name>`). NOT registered in vibe.conf
# and NOT counted toward the multi-app threshold.
APPS_INTEGRATIONS="glm-ocr tailscale tools"

apps_is_supported() {
    local app="$1"
    case " $APPS_SUPPORTED " in
        *" $app "*) return 0 ;;
        *)          return 1 ;;
    esac
}

apps_is_integration() {
    local app="$1"
    case " $APPS_INTEGRATIONS " in
        *" $app "*) return 0 ;;
        *)          return 1 ;;
    esac
}

# Where the vendored compose files for an app live in this repo.
apps_dir() {
    printf '%s\n' "${VIBE_PREFIX}/apps/$1"
}

# Wrapper around `docker compose` with the right -f / --env-file / --project-name.
# Project name is stable across single-app and multi-app modes so volumes survive
# mode transitions.
#
# VIBE_HOST is exported into the compose substitution context so per-app
# grouped overlays (which reference `${VIBE_HOST:-vibe.local}` to build
# absolute URLs and CORS origins) pick up the operator-chosen host instead
# of the placeholder default.
apps_compose() {
    local app="$1"; shift
    local mode host
    mode="$(config_get mode)"
    host="$(config_get host)"
    [ -z "$host" ] && host="vibe.local"
    local dir env
    dir="$(apps_dir "$app")"
    env="$(secrets_env_path "$app")"
    [ -f "$env" ] || die "env file missing: $env (run 'vibe install ${app}' first)"

    local args=(--project-name "vibe-${app}" --env-file "$env" -f "${dir}/docker-compose.yml")
    if [ "$mode" = "multi" ]; then
        args+=(-f "${dir}/docker-compose.grouped.yml")
    fi
    VIBE_HOST="$host" docker compose "${args[@]}" "$@"
}

# ---------- Per-app data directory layout ----------
# Each app gets a fixed set of host bind-mount targets under /var/lib/vibe/<app>/.
# We pre-create them with the right ownership before `docker compose up` so
# Postgres / Redis volumes don't end up root-owned.
apps_ensure_datadirs() {
    local app="$1"
    require_root
    local base="${VIBE_DATA}/${app}"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$base"
    case "$app" in
        mybooks)
            # postgres:16-alpine runs as uid 70 (postgres user in the container).
            # The Postgres entrypoint chowns its data dir to uid 70 on first
            # start as long as it can write to it, so 0700 owned by uid 70 is
            # the safest pre-creation: avoids a race where the entrypoint runs
            # as root for chown but the kernel later denies the postgres user
            # write access.
            install -d -m 0700 "$base/postgres-data"
            chown 70:70 "$base/postgres-data" 2>/dev/null || true
            # redis:7-alpine runs as uid 999 (redis user). Unlike Postgres,
            # the Redis entrypoint does NOT fix ownership — the container
            # never runs as root. The host directory MUST be writable by
            # uid 999 or AOF writes fail with "Permission denied".
            install -d -m 0750 "$base/redis-data"
            chown 999:999 "$base/redis-data" 2>/dev/null || true
            install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$base/uploads"
            install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$base/backups"
            install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$base/glm-ocr-models"
            ;;
        connect)
            install -d -m 0700 "$base/postgres-data"
            chown 70:70 "$base/postgres-data" 2>/dev/null || true
            install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$base/uploads"
            install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$base/tls"
            install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$base/outbox"
            ;;
        tb)
            # Vendored compose uses Docker named volumes (pgdata, uploads,
            # backups, ocr-cache). They live under /var/lib/docker/volumes/
            # and are managed by Docker. We still create the per-app base
            # dir so backups + future bind-mount overrides have a home.
            : ;;
        payroll)
            # Payroll uses named volumes (pgdata, caddy-data, exports) plus
            # bind mounts for WAL archive and update-control. Those host paths
            # are created in apps_install_payroll itself.
            : ;;
        tax)
            # postgres:16-alpine runs as uid 70.
            install -d -m 0700 "$base/postgres-data"
            chown 70:70 "$base/postgres-data" 2>/dev/null || true
            # redis:7-alpine runs as uid 999. AOF writes need uid 999
            # to own the directory — see the mybooks block above for
            # the full rationale.
            install -d -m 0750 "$base/redis-data"
            chown 999:999 "$base/redis-data" 2>/dev/null || true
            # Skills repo clone + per-user workspaces. Owned by the
            # node:20-alpine api container's uid (1000) — `node` user.
            install -d -m 0750 "$base/workspaces"
            chown 1000:1000 "$base/workspaces" 2>/dev/null || true
            # Uploaded attachments (PDFs, screenshots) referenced by
            # chats. Same node uid as workspaces.
            install -d -m 0750 "$base/attachments"
            chown 1000:1000 "$base/attachments" 2>/dev/null || true
            # Backup target — pg_dump output + skills snapshot.
            install -d -m 0750 "$base/backups"
            chown 1000:1000 "$base/backups" 2>/dev/null || true
            ;;
    esac
    ok "data dirs ready under ${base}/"
}

# ---------- Install ----------

# Install dispatcher — `vibe install <app> [opts]`.
apps_install() {
    local app="${1:-}"
    [ -n "$app" ] || die "usage: vibe install <app> [--cloudflare-tunnel <token>]"
    require_root
    config_init

    # Optional integrations short-circuit the main flow — they don't enter
    # the installed= registry or trigger mode promotion.
    if apps_is_integration "$app"; then
        case "$app" in
            glm-ocr)   glm_ocr_install ;;
            tailscale) tailscale_install ;;
            tools)     tools_install ;;
        esac
        return $?
    fi

    apps_is_supported "$app" \
        || die "unknown app: $app (supported: $APPS_SUPPORTED $APPS_INTEGRATIONS)"

    # Already installed?
    if config_installed_has "$app"; then
        log "${app} is already installed — re-running install for idempotence"
    fi

    config_snapshot

    # Run the install workload in a subshell. `die`/`exit` inside the workload
    # exits the subshell only — the parent catches the non-zero rc and runs
    # rollback. This is more reliable than `trap ... ERR` (which doesn't fire
    # on explicit exit) because every per-app installer's failure path uses
    # `die` extensively.
    local rc=0
    ( _apps_install_workload "$app" "$@" ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        apps_install_rollback "$app"
        return $rc
    fi

    config_installed_add "$app"

    # Always-multi: ingress is up by definition, so always reload to pick
    # up the new app's caddy.fragment. The reload is a SIGHUP (no
    # downtime); even with the legacy mode=single fallback below it's
    # cheap enough to call unconditionally.
    if [ "$(mode_current)" = "multi" ]; then
        ingress_reload
    fi

    config_commit
    # Clear the promotion marker — install succeeded, no recovery needed.
    rm -f "${VIBE_DATA}/.install-promoted-flag" 2>/dev/null || true
    ok "${app} installed"
}

# Runs in a SUBSHELL launched by apps_install. set -e is inherited; failures
# (including `die` -> exit 1) terminate the subshell with the failed rc.
_apps_install_workload() {
    local app="$1"; shift

    # Always-multi-app: every install lands behind the shared Caddy ingress.
    # If for any reason mode_current() is still 'single' (mid-migration of a
    # legacy config, or someone forced single mode for testing), bring the
    # ingress up + flip mode before the per-app installer runs. Adding apps
    # never changes URLs because we're already in the multi shape.
    if [ "$(mode_current)" != "multi" ]; then
        log "ensuring multi-app mode (Caddy ingress at https://$(config_get host)/)..."
        local existing=()
        while IFS= read -r a; do existing+=("$a"); done < <(config_installed_list)
        if [ "${#existing[@]}" -gt 0 ]; then
            mode_promote_to_multi "${existing[@]}"
            # Drop a marker the parent's rollback path can read. Promotion
            # succeeded; if the per-app installer below fails, vibe.conf
            # rollback alone won't reverse the mode flip — the marker
            # tells apps_install_rollback to print the recovery hint.
            : > "${VIBE_DATA}/.install-promoted-flag" 2>/dev/null || true
        else
            config_set mode multi
            ingress_up
            ingress_trust_local_ca
        fi
    fi

    # Dispatch to per-app installer. Unknown app = exit non-zero so the
    # parent's rollback path runs.
    case "$app" in
        mybooks) apps_install_mybooks "$app" "$@" ;;
        connect) apps_install_connect "$app" "$@" ;;
        tb)      apps_install_tb      "$app" "$@" ;;
        payroll) apps_install_payroll "$app" "$@" ;;
        tax)     apps_install_tax     "$app" "$@" ;;
        *)       die "install for '$app' is not implemented" ;;
    esac
}

apps_install_rollback() {
    local app="$1"
    warn "install of '${app}' failed — rolling back vibe.conf"
    config_restore
    # Leave any data dirs alone (the operator may want to debug). We do tear
    # down stray containers from the failed up — but only if the env file
    # exists (apps_compose dies otherwise and a half-rolled-back state is
    # worse than the alternative).
    if has_cmd docker && [ -f "$(secrets_env_path "$app")" ]; then
        apps_compose "$app" down --remove-orphans 2>/dev/null || true
    fi

    # If the failed install promoted single→multi BEFORE crashing, the
    # appliance is now in a mixed state: vibe.conf says single (after
    # config_restore), but the host is actually running Caddy + the
    # previously-installed app(s) in multi-app shape. Surface this so
    # the operator can recover instead of chasing ghost behavior.
    #
    # The flag file is dropped by _apps_install_workload right after
    # mode_promote_to_multi succeeds (since the workload runs in a
    # subshell, an env var wouldn't propagate back to this function).
    if [ -f "${VIBE_DATA}/.install-promoted-flag" ]; then
        rm -f "${VIBE_DATA}/.install-promoted-flag"
        echo
        warn "================ partial recovery ================"
        warn "  This install promoted the host to multi-app mode before"
        warn "  failing. vibe.conf was rolled back to its pre-install"
        warn "  state, but the existing app(s) are still running in"
        warn "  multi-app shape and the Caddy ingress is up."
        warn ""
        warn "  Pick ONE recovery path:"
        warn ""
        warn "  A) Stay multi-app, fix the underlying issue, retry:"
        warn "       sudo vibe mode multi              # re-sync state"
        warn "       sudo vibe install ${app}      # retry install"
        warn ""
        warn "  B) Demote back to single-app:"
        warn "       sudo vibe mode single             # tear down ingress"
        warn "                                        # + restart sole app"
        warn "===================================================="
    fi
}

# ---------- MyBooks install ----------
apps_install_mybooks() {
    shift || true   # drop "$app"
    local cf_token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --cloudflare-tunnel)
                cf_token="${2:-}"; shift 2
                [ -n "$cf_token" ] || die "--cloudflare-tunnel requires a token argument"
                ;;
            *) warn "ignoring unknown flag: $1"; shift ;;
        esac
    done

    # If install.sh stashed a tunnel token during bootstrap (cf-tunnel TLS
    # mode) and the operator didn't pass --cloudflare-tunnel explicitly,
    # use the stash. Cleared after first consumption so a subsequent
    # `vibe install connect` doesn't silently reuse it.
    if [ -z "$cf_token" ]; then
        cf_token="$(cloudflare_read_stashed_token 2>/dev/null || true)"
        if [ -n "$cf_token" ]; then
            log "using cloudflare tunnel token stashed at $(cloudflare_token_stash_path)"
            cloudflare_clear_stashed_token
        fi
    fi

    apps_ensure_datadirs mybooks

    # Render env (idempotent — preserves any existing values).
    secrets_render_env_template mybooks
    secrets_assert_no_placeholders mybooks

    # License activation (env, prompt, or trial fallback).
    license_activate mybooks

    # Cloudflare Tunnel token (if supplied at install time).
    if [ -n "$cf_token" ]; then
        secrets_set mybooks CLOUDFLARE_TUNNEL_TOKEN "$cf_token"
        log "cloudflare: tunnel token written to env (sidecar will start under --profile tunnel)"
    fi

    log "pulling GHCR images for mybooks..."
    apps_compose mybooks pull --quiet
    ok "images pulled"

    log "starting mybooks stack..."
    if [ -n "$cf_token" ]; then
        apps_compose mybooks --profile tunnel up -d --remove-orphans
    else
        apps_compose mybooks up -d --remove-orphans
    fi

    apps_wait_healthy mybooks api 180 || die "mybooks api failed to become healthy"
    apps_post_install_hint mybooks
}

# ---------- Connect install ----------
apps_install_connect() {
    shift || true
    local cf_token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --cloudflare-tunnel) cf_token="${2:-}"; shift 2 ;;
            *) warn "ignoring unknown flag: $1"; shift ;;
        esac
    done

    if [ -z "$cf_token" ]; then
        cf_token="$(cloudflare_read_stashed_token 2>/dev/null || true)"
        if [ -n "$cf_token" ]; then
            log "using cloudflare tunnel token stashed at $(cloudflare_token_stash_path)"
            cloudflare_clear_stashed_token
        fi
    fi

    apps_ensure_datadirs connect

    # Render env first (placeholders use the SAME postgres password we then
    # write to the file-secret). We pre-generate the password so both the
    # env file's DATABASE_URL and the file-secret carry the same value.
    local pg_password
    pg_password="$(secrets_read_file connect postgres_password 2>/dev/null || true)"
    if [ -z "$pg_password" ]; then
        pg_password="$(secrets_db_password)"
    fi

    # Custom render: connect's env.template embeds POSTGRES_PASSWORD inline
    # in DATABASE_URL, so we substitute here instead of through the generic
    # secrets_render_env_template path.
    local out tpl
    out="$(secrets_env_path connect)"
    tpl="${VIBE_PREFIX}/apps/connect/env.template"
    if [ ! -f "$out" ]; then
        secrets_ensure_envdir connect
        local sess
        sess="$(secrets_b64_48)"
        : "${VIBE_CONNECT_VERSION:=latest}"
        : "${DISABLE_LICENSE_CHECK:=1}"
        : "${LICENSE_TOKEN:=}"
        sed \
            -e "s|@SESSION_SECRET@|${sess}|g" \
            -e "s|@POSTGRES_PASSWORD@|${pg_password}|g" \
            -e "s|@VIBE_CONNECT_VERSION@|${VIBE_CONNECT_VERSION}|g" \
            -e "s|@DISABLE_LICENSE_CHECK@|${DISABLE_LICENSE_CHECK}|g" \
            -e "s|@LICENSE_TOKEN@|${LICENSE_TOKEN}|g" \
            "$tpl" > "$out"
        chown "$VIBE_USER:$VIBE_USER" "$out"
        chmod 0600 "$out"
        ok "rendered $out (mode 0600)"
    else
        warn "env file already exists at $out — not overwriting"
    fi

    # Postgres file-secret (mounted as /run/secrets/postgres_password in the
    # postgres container per the upstream compose).
    secrets_write_file connect postgres_password "$pg_password"

    secrets_assert_no_placeholders connect
    license_activate connect

    if [ -n "$cf_token" ]; then
        secrets_set connect CLOUDFLARE_TUNNEL_TOKEN "$cf_token"
    fi

    log "pulling GHCR images for connect..."
    apps_compose connect pull --quiet
    ok "images pulled"

    log "starting connect stack..."
    if [ -n "$cf_token" ]; then
        apps_compose connect --profile tunnel up -d --remove-orphans
    else
        apps_compose connect up -d --remove-orphans
    fi

    apps_wait_healthy connect app 180 || die "connect app failed to become healthy"
    apps_post_install_hint connect
}

# ---------- TB install ----------
apps_install_tb() {
    shift || true
    local cf_token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --cloudflare-tunnel) cf_token="${2:-}"; shift 2 ;;
            *) warn "ignoring unknown flag: $1"; shift ;;
        esac
    done

    apps_ensure_datadirs tb

    # TB env: DB_PASSWORD, JWT_SECRET (32-hex), ENCRYPTION_KEY (32-hex).
    local out tpl
    out="$(secrets_env_path tb)"
    tpl="${VIBE_PREFIX}/apps/tb/env.template"
    if [ ! -f "$out" ]; then
        secrets_ensure_envdir tb
        local db jwt enc
        db="$(secrets_db_password)"
        jwt="$(secrets_hex32)"
        enc="$(secrets_hex32)"
        : "${VIBE_TB_VERSION:=latest}"
        : "${DISABLE_LICENSE_CHECK:=1}"
        : "${LICENSE_TOKEN:=}"
        sed \
            -e "s|@DB_PASSWORD@|${db}|g" \
            -e "s|@JWT_SECRET@|${jwt}|g" \
            -e "s|@ENCRYPTION_KEY@|${enc}|g" \
            -e "s|@VIBE_TB_VERSION@|${VIBE_TB_VERSION}|g" \
            -e "s|@DISABLE_LICENSE_CHECK@|${DISABLE_LICENSE_CHECK}|g" \
            -e "s|@LICENSE_TOKEN@|${LICENSE_TOKEN}|g" \
            "$tpl" > "$out"
        chown "$VIBE_USER:$VIBE_USER" "$out"
        chmod 0600 "$out"
        ok "rendered $out (mode 0600)"
    else
        warn "env file already exists at $out — not overwriting"
    fi

    # ALLOWED_ORIGIN is required in production — TB's api exits at boot if
    # it's blank. Set it for both modes; multi-app uses https://<host>,
    # single-app uses http://<host>:<WEB_PUBLISH_PORT>.
    local host
    host="$(config_get host)"
    [ -z "$host" ] && host="vibe.local"
    if [ "$(mode_current)" = "multi" ]; then
        secrets_set tb ALLOWED_ORIGIN "https://${host}"
        secrets_set tb APP_BASE_URL   "https://${host}/tb"
    else
        local port
        port="$(secrets_get tb WEB_PUBLISH_PORT 2>/dev/null || true)"
        [ -z "$port" ] && port=8081
        secrets_set tb ALLOWED_ORIGIN "http://${host}:${port}"
        secrets_set tb APP_BASE_URL   "http://${host}:${port}"
    fi

    secrets_assert_no_placeholders tb
    license_activate tb

    if [ -n "$cf_token" ]; then
        secrets_set tb CLOUDFLARE_TUNNEL_TOKEN "$cf_token"
    fi

    log "pulling GHCR images for tb..."
    apps_compose tb pull --quiet
    ok "images pulled"

    log "starting tb stack..."
    apps_compose tb up -d --remove-orphans

    apps_wait_healthy tb api 180 || die "tb api failed to become healthy"
    apps_post_install_hint tb
}

# ---------- Payroll install ----------
apps_install_payroll() {
    shift || true
    local cf_token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --cloudflare-tunnel) cf_token="${2:-}"; shift 2 ;;
            *) warn "ignoring unknown flag: $1"; shift ;;
        esac
    done

    if [ -z "$cf_token" ]; then
        cf_token="$(cloudflare_read_stashed_token 2>/dev/null || true)"
        if [ -n "$cf_token" ]; then
            log "using cloudflare tunnel token stashed at $(cloudflare_token_stash_path)"
            cloudflare_clear_stashed_token
        fi
    fi

    apps_ensure_datadirs payroll
    # wal-archive is bind-mounted into the postgres container at
    # /wal-archive. The postgres `archive_command` runs as uid 70 inside
    # the container and writes WAL segments to that path — so the host
    # dir MUST be writable by uid 70, not by `vibe` (which is a system
    # uid that postgres has no membership in). With vibe-only ownership
    # the archive_command silently fails on every WAL segment and PITR
    # is dead in the water.
    install -d -m 0750 "${VIBE_DATA}/payroll/wal-archive"
    chown 70:70 "${VIBE_DATA}/payroll/wal-archive" 2>/dev/null || true
    # update-control is the api-container ↔ host bridge for self-service
    # updates. The api runs as uid 1000 (node:20-alpine's `node` user)
    # which writes the request file the host's update.sh consumes.
    install -d -m 0750 "${VIBE_DATA}/payroll/update-control"
    chown 1000:1000 "${VIBE_DATA}/payroll/update-control" 2>/dev/null || true

    local out tpl
    out="$(secrets_env_path payroll)"
    tpl="${VIBE_PREFIX}/apps/payroll/env.template"
    if [ ! -f "$out" ]; then
        secrets_ensure_envdir payroll
        local pg jwt enc
        pg="$(secrets_db_password)"
        jwt="$(secrets_b64_48)"
        enc="$(secrets_hex32)"
        local appliance_id
        appliance_id="$(machine_id | head -c 16)"
        local host
        host="$(config_get host)"
        : "${VIBE_PAYROLL_VERSION:=latest}"
        : "${DISABLE_LICENSE_CHECK:=1}"
        : "${LICENSE_TOKEN:=}"
        sed \
            -e "s|@POSTGRES_PASSWORD@|${pg}|g" \
            -e "s|@JWT_SECRET@|${jwt}|g" \
            -e "s|@SECRETS_ENCRYPTION_KEY@|${enc}|g" \
            -e "s|@APPLIANCE_ID@|${appliance_id}|g" \
            -e "s|@VIBE_HOST@|${host:-vibe.local}|g" \
            -e "s|@VIBE_PREFIX@|${VIBE_PREFIX}|g" \
            -e "s|@VIBE_PAYROLL_VERSION@|${VIBE_PAYROLL_VERSION}|g" \
            -e "s|@DISABLE_LICENSE_CHECK@|${DISABLE_LICENSE_CHECK}|g" \
            -e "s|@LICENSE_TOKEN@|${LICENSE_TOKEN}|g" \
            "$tpl" > "$out"
        chown "$VIBE_USER:$VIBE_USER" "$out"
        chmod 0600 "$out"
        ok "rendered $out (mode 0600)"
    else
        warn "env file already exists at $out — not overwriting"
    fi

    # CORS_ORIGIN is required for Payroll's api in both modes (api rejects
    # browser requests without it). Multi-app uses https://<host>; single-app
    # uses http://<host>:<CADDY_HTTP_PORT> (the bundled Caddy is the public
    # entry point in single-app mode).
    local host_p
    host_p="$(config_get host)"
    [ -z "$host_p" ] && host_p="vibe.local"
    if [ "$(mode_current)" = "multi" ]; then
        secrets_set payroll CORS_ORIGIN "https://${host_p}"
        secrets_set payroll COOKIE_PATH "/payroll"
    else
        local cport
        cport="$(secrets_get payroll CADDY_HTTP_PORT 2>/dev/null || true)"
        [ -z "$cport" ] && cport=80
        if [ "$cport" = "80" ]; then
            secrets_set payroll CORS_ORIGIN "http://${host_p}"
        else
            secrets_set payroll CORS_ORIGIN "http://${host_p}:${cport}"
        fi
        secrets_set payroll COOKIE_PATH "/"
    fi

    secrets_assert_no_placeholders payroll
    license_activate payroll

    if [ -n "$cf_token" ]; then
        secrets_set payroll CLOUDFLARE_TUNNEL_TOKEN "$cf_token"
    fi

    # Verify the GHCR images exist before pulling — Payroll publishes lag
    # behind MyBooks/TB/Connect and prereq P-A may not be in place yet.
    if ! docker manifest inspect "ghcr.io/kisaesdevlab/vibe-payroll-api:${VIBE_PAYROLL_VERSION:-latest}" >/dev/null 2>&1; then
        warn "ghcr.io/kisaesdevlab/vibe-payroll-api:${VIBE_PAYROLL_VERSION:-latest} not found"
        warn "prereq P-A: Payroll's docker-publish.yml workflow needs to land before this can install."
        die "aborting (set VIBE_PAYROLL_VERSION to an existing tag and re-run)"
    fi

    log "pulling GHCR images for payroll..."
    apps_compose payroll pull --quiet
    ok "images pulled"

    log "starting payroll stack..."
    # Single-app mode runs the bundled Caddy under --profile public.
    # Multi-app mode disables it via the installer's grouped overlay (caddy
    # service has profiles: ['unused']).
    if [ "$(mode_current)" = "single" ]; then
        apps_compose payroll --profile public up -d --remove-orphans
    else
        apps_compose payroll up -d --remove-orphans
    fi

    apps_wait_healthy payroll api 180 || die "payroll api failed to become healthy"
    apps_post_install_hint payroll
}

# ---------- Tax (Vibe Tax Research Chat) install ----------
#
# Stack: postgres + redis + api + web. The new piece vs other apps is
# Redis — every per-app data dir is created above; here we only render
# the env file + assert images exist + bring the stack up.
#
# Cloudflare Tunnel: the upstream tax-chat compose doesn't ship a
# cloudflared sidecar (yet). The --cloudflare-tunnel flag is accepted
# for symmetry with the other apps but writes the token to the env
# file's CLOUDFLARE_TUNNEL_TOKEN slot for a future overlay to consume;
# today it has no effect on the running stack. Operators wanting a
# tunnel today can use the host-level cloudflared via the integrations
# UI.
apps_install_tax() {
    shift || true
    local cf_token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --cloudflare-tunnel) cf_token="${2:-}"; shift 2 ;;
            *) warn "ignoring unknown flag: $1"; shift ;;
        esac
    done

    if [ -z "$cf_token" ]; then
        cf_token="$(cloudflare_read_stashed_token 2>/dev/null || true)"
        if [ -n "$cf_token" ]; then
            log "using cloudflare tunnel token stashed at $(cloudflare_token_stash_path)"
            cloudflare_clear_stashed_token
        fi
    fi

    apps_ensure_datadirs tax

    local out tpl
    out="$(secrets_env_path tax)"
    tpl="${VIBE_PREFIX}/apps/tax/env.template"
    if [ ! -f "$out" ]; then
        secrets_ensure_envdir tax
        local pg master jwt jwt_refresh
        pg="$(secrets_db_password)"
        # MASTER_KEY is 64 hex chars (32 bytes) — the AES-256-GCM HKDF
        # input the api uses to encrypt the operator's Anthropic key
        # at rest. JWT secrets are 64 hex (32 bytes) each — comfortably
        # above the api's z.string().min(32) Zod check.
        master="$(secrets_hex32)"
        jwt="$(secrets_hex32)"
        jwt_refresh="$(secrets_hex32)"
        local host
        host="$(config_get host)"
        : "${VIBE_TAX_VERSION:=latest}"
        : "${DISABLE_LICENSE_CHECK:=1}"
        : "${LICENSE_TOKEN:=}"
        sed \
            -e "s|@POSTGRES_PASSWORD@|${pg}|g" \
            -e "s|@MASTER_KEY@|${master}|g" \
            -e "s|@JWT_SECRET@|${jwt}|g" \
            -e "s|@JWT_REFRESH_SECRET@|${jwt_refresh}|g" \
            -e "s|@VIBE_HOST@|${host:-vibe.local}|g" \
            -e "s|@VIBE_TAX_VERSION@|${VIBE_TAX_VERSION}|g" \
            -e "s|@DISABLE_LICENSE_CHECK@|${DISABLE_LICENSE_CHECK}|g" \
            -e "s|@LICENSE_TOKEN@|${LICENSE_TOKEN}|g" \
            "$tpl" > "$out"
        chown "$VIBE_USER:$VIBE_USER" "$out"
        chmod 0600 "$out"
        ok "rendered $out (mode 0600)"
    else
        warn "env file already exists at $out — not overwriting"
    fi

    # Re-stamp PUBLIC_BASE_URL on every install so a host change picks up
    # without needing to manually edit the env file. Same approach as
    # payroll's CORS_ORIGIN re-stamping above.
    local host_t
    host_t="$(config_get host)"
    [ -z "$host_t" ] && host_t="vibe.local"
    if [ "$(mode_current)" = "multi" ]; then
        secrets_set tax PUBLIC_BASE_URL "https://${host_t}"
        secrets_set tax VITE_BASE_PATH "/tax/"
    else
        local port
        port="$(secrets_get tax WEB_PUBLISH_PORT 2>/dev/null || true)"
        [ -z "$port" ] && port=8082
        secrets_set tax PUBLIC_BASE_URL "http://${host_t}:${port}"
        secrets_set tax VITE_BASE_PATH "/"
    fi

    secrets_assert_no_placeholders tax
    license_activate tax

    if [ -n "$cf_token" ]; then
        secrets_set tax CLOUDFLARE_TUNNEL_TOKEN "$cf_token"
        warn "cloudflare token stored — note: tax-chat doesn't ship a tunnel sidecar yet"
    fi

    # Verify GHCR images exist before pulling — prereq T-A (the
    # release.yml workflow on Vibe-Tax-Research-Chat:feat/installer-readiness)
    # may not have shipped yet.
    local tag="${VIBE_TAX_VERSION:-latest}"
    if ! docker manifest inspect "ghcr.io/kisaesdevlab/vibe-tax-api:${tag}" >/dev/null 2>&1; then
        warn "ghcr.io/kisaesdevlab/vibe-tax-api:${tag} not found"
        warn "prereq T-A: tax-chat's release.yml workflow needs to ship + tag before this can install."
        die "aborting (set VIBE_TAX_VERSION to an existing tag and re-run)"
    fi

    log "pulling GHCR images for tax..."
    apps_compose tax pull --quiet
    ok "images pulled"

    log "starting tax stack..."
    apps_compose tax up -d --remove-orphans

    apps_wait_healthy tax api 240 || die "tax api failed to become healthy"
    apps_post_install_hint tax
}

# ---------- Health-wait helper ----------
# Polls `docker compose ps` for the named service until either:
#   - Health field reports `healthy`, OR
#   - Service has no healthcheck defined AND State=running for >= 30 seconds.
# The fallback covers Payroll's api/web/caddy which don't ship healthchecks
# in the upstream prod compose.
apps_wait_healthy() {
    local app="$1" service="$2" timeout="${3:-120}"
    local deadline running_since=0
    deadline=$(( $(date +%s) + timeout ))
    log "waiting for ${app}/${service} to become healthy (timeout ${timeout}s)..."
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # `docker compose ps --format json` returns one JSON object per
        # service on stdout. Take the first line, then read Health + State.
        local json health state
        json="$(apps_compose "$app" ps --format json "$service" 2>/dev/null | head -1)"
        health="$(printf '%s' "$json" | jq -r 'if type=="array" then .[0].Health else .Health end' 2>/dev/null)"
        state="$(printf '%s' "$json" | jq -r 'if type=="array" then .[0].State else .State end' 2>/dev/null)"
        case "$health" in
            healthy)
                ok "${app}/${service} healthy"
                return 0
                ;;
            unhealthy)
                err "${app}/${service} reported unhealthy"
                return 1
                ;;
            ""|null)
                # No healthcheck defined — accept State=running for >= 30s.
                if [ "$state" = "running" ]; then
                    if [ "$running_since" -eq 0 ]; then
                        running_since="$(date +%s)"
                    elif [ "$(( $(date +%s) - running_since ))" -ge 30 ]; then
                        ok "${app}/${service} running (no healthcheck defined; running ≥30s)"
                        return 0
                    fi
                else
                    running_since=0
                fi
                sleep 3
                ;;
            *) sleep 3 ;;
        esac
    done
    err "${app}/${service} did not reach healthy within ${timeout}s"
    apps_compose "$app" ps "$service" >&2 || true
    return 1
}

apps_post_install_hint() {
    local app="$1"
    local host
    host="$(config_get host)"
    [ -z "$host" ] && host="vibe.local"

    # Always-multi-app: every install lands behind https://<host>/<app>/.
    # The legacy single-app per-port hints have been removed — they were
    # both inconsistent (e.g. tb hint claimed port 5173, the actual web
    # publish was 8081) and confusing for operators since adding a second
    # app would change the URL out from under them. URLs are now stable
    # from first install.
    echo
    ok "${app^} is up at:"
    echo "    https://${host}/${app}/"
    echo
    log "next: 'sudo vibe install <app>' to add another, or 'vibe status' to inspect."
}

# ---------- Status ----------
# Lightweight per-app status used by `vibe status` (PR2 prints a one-liner).
apps_version_key() {
    # The env-var name the vendored compose actually reads to choose the
    # GHCR tag — must match the `${VAR:-latest}` in the compose's `image:`
    # lines, NOT the install-time placeholder name. Mismatches mean
    # `vibe upgrade <app> --to X` writes a key the compose ignores and
    # the upgrade silently does nothing.
    case "$1" in
        # mybooks: image: ...:${VIBE_MYBOOKS_VERSION:-latest}
        mybooks) printf 'VIBE_MYBOOKS_VERSION\n' ;;
        # connect: image: ...:${VERSION:-latest}
        connect) printf 'VERSION\n' ;;
        # tb: image: ...:${IMAGE_TAG:-latest}. The env.template renders
        # `IMAGE_TAG=@VIBE_TB_VERSION@` so VIBE_TB_VERSION is only the
        # install-time placeholder; runtime read-key is IMAGE_TAG.
        tb)      printf 'IMAGE_TAG\n' ;;
        # payroll: image: ...:${IMAGE_TAG:-latest}. Same shape as tb.
        payroll) printf 'IMAGE_TAG\n' ;;
        # tax: image: ...:${IMAGE_TAG:-latest}. We expose VIBE_TAX_VERSION
        # as the operator-friendly install-time name; runtime is IMAGE_TAG.
        tax)     printf 'IMAGE_TAG\n' ;;
        # admin: image: ...:${VERSION:-latest}
        admin)   printf 'VERSION\n' ;;
        *)       printf 'VERSION\n' ;;
    esac
}

# ---------- Upgrade ----------
# `vibe upgrade <app> [--to VER]` — pull a new tag and recreate containers.
# Defaults to `latest` if no --to specified. The recreated containers run
# any on-boot migrations the upstream image baked in (MyBooks worker runs
# drizzle-kit migrate; Payroll respects MIGRATE_ON_BOOT=true; TB's api
# image migrates automatically via its entrypoint).
#
# We do NOT roll back on failure — the operator should diagnose and either
# fix or manually downgrade. We log the previous tag clearly so they can.
apps_upgrade() {
    require_root
    local app="${1:-}"
    [ -n "$app" ] || die "usage: vibe upgrade <app> [--to <version>]"
    # `admin` is the system-installed appliance management app — it
    # isn't in APPS_SUPPORTED (so it doesn't show up in `vibe install`
    # / `vibe uninstall` lists) but operators still need a way to
    # bump it without re-running install.sh by hand. Dispatch to a
    # dedicated upgrade path.
    if [ "$app" = "admin" ]; then
        apps_upgrade_admin "$@"
        return $?
    fi
    apps_is_supported "$app" || die "unknown app: $app"
    config_installed_has "$app" || die "$app is not installed (use 'vibe install $app')"
    shift

    local target=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --to) target="${2:-}"; shift 2 ;;
            *) warn "ignoring unknown flag: $1"; shift ;;
        esac
    done

    local key prev
    key="$(apps_version_key "$app")"
    prev="$(secrets_get "$app" "$key")"
    [ -z "$prev" ] && prev="latest"

    [ -z "$target" ] && target="latest"

    if [ "$target" = "$prev" ]; then
        log "${app} already pinned to ${target}; pulling to refresh anyway"
    else
        log "upgrading ${app}: ${prev} → ${target}"
    fi

    secrets_set "$app" "$key" "$target"

    if ! apps_compose "$app" pull --quiet; then
        warn "pull failed — restoring previous tag (${prev}) in env file"
        secrets_set "$app" "$key" "$prev"
        die "image pull failed; rollback applied to env file (containers untouched)"
    fi

    log "recreating ${app} containers with new tag..."
    if ! apps_compose "$app" up -d --remove-orphans; then
        err "containers failed to come up on ${target}"
        warn "rollback with: vibe upgrade ${app} --to ${prev}"
        return 1
    fi

    apps_wait_healthy "$app" "$(apps_primary_service "$app")" 240 || {
        err "${app} did not become healthy on ${target}"
        warn "rollback with: vibe upgrade ${app} --to ${prev}"
        return 1
    }

    ok "${app} upgraded to ${target}"
}

# Service name to wait on for healthy after install/upgrade.
apps_primary_service() {
    case "$1" in
        mybooks) printf 'api\n' ;;
        connect) printf 'app\n' ;;
        tb)      printf 'api\n' ;;
        payroll) printf 'api\n' ;;
        tax)     printf 'api\n' ;;
        admin)   printf 'admin\n' ;;
        *) printf 'api\n' ;;
    esac
}

# ---------- Admin self-upgrade ----------
# `vibe upgrade admin [--to VER]` — bump the appliance management app's
# image without re-running install.sh. Mirrors the shape of apps_upgrade
# but bypasses the user-app machinery (admin isn't in APPS_SUPPORTED or
# config's `installed=` list — it's system-installed).
#
# Important UX note: when an operator triggers this from the admin web
# UI itself, the admin container restarts mid-flight and their browser
# session loses its connection to the streaming JobLogPanel. They need
# to refresh once the new container is up. The CLI flow has no such
# wrinkle — log goes to the operator's terminal, the recreated
# container reconnects to the same vibed socket on next browser visit.
apps_upgrade_admin() {
    # Caller dispatched here from apps_upgrade with $1 == "admin".
    # Drop that and parse --to from the remainder.
    shift || true
    local target=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --to) target="${2:-}"; shift 2 ;;
            *) warn "ignoring unknown flag: $1"; shift ;;
        esac
    done

    local env_file="${VIBE_ETC}/admin/.env"
    if [ ! -f "$env_file" ]; then
        die "admin not installed: $env_file missing. Run install.sh to bootstrap."
    fi

    local prev
    prev="$(secrets_get admin VERSION 2>/dev/null || true)"
    [ -z "$prev" ] && prev="latest"
    [ -z "$target" ] && target="latest"

    if [ "$target" = "$prev" ]; then
        log "admin already pinned to ${target}; pulling to refresh anyway"
    else
        log "upgrading admin: ${prev} → ${target}"
    fi

    secrets_set admin VERSION "$target"

    # apps_compose handles the project name + overlay layering for us.
    # The admin's vendored compose lives at apps/admin/, the env file
    # at /etc/vibe/admin/.env — both already match the standard
    # apps_compose contract, so admin slots in like any other app.
    if ! apps_compose admin pull --quiet; then
        warn "pull failed — restoring previous tag (${prev}) in env file"
        secrets_set admin VERSION "$prev"
        die "image pull failed; rollback applied to env file (containers untouched)"
    fi

    log "recreating admin containers..."
    if ! apps_compose admin up -d --remove-orphans; then
        err "containers failed to come up on ${target}"
        warn "rollback with: vibe upgrade admin --to ${prev}"
        return 1
    fi

    apps_wait_healthy admin admin 240 || {
        err "admin did not become healthy on ${target}"
        warn "rollback with: vibe upgrade admin --to ${prev}"
        return 1
    }

    ok "admin upgraded to ${target}"
    log "if you ran this from the admin web UI itself, refresh your browser"
    log "to re-attach to the new container."
}

# ---------- Restore ----------
# `vibe restore <app> <tarball>` — replace the app's host-bind data and env
# from a previous `vibe backup <app>` snapshot. The shape of the tarball we
# accept is the one apps_backup writes: a single .tar.gz at
# /var/lib/vibe/<app>/backups/snapshot-<ts>.tar.gz containing the absolute
# paths /var/lib/vibe/<app>/ + /etc/vibe/<app>/. We deliberately do NOT
# accept the multi-file uninstall-archive format (host-data.tar.gz +
# etc.tar.gz + per-volume tarballs) — that's the operator's manual
# restore path and forking the format here would be its own can of worms.
#
# Flow:
#   1. Validate the tarball (gzipped tar, contains the expected paths).
#   2. Stop the app's containers.
#   3. Take a pre-restore safety archive of the current state — if the
#      restore goes sideways the operator can roll back from this.
#   4. Wipe /var/lib/vibe/<app>/ + /etc/vibe/<app>/.
#   5. tar -xzf the backup at /, re-applying every byte of the snapshot.
#   6. Re-create the per-uid ownership for postgres/redis data dirs
#      (apps_ensure_datadirs is idempotent + chowns 70:70 / 999:999).
#   7. Start the app's containers; wait for the primary service to be
#      healthy. The image's startup-time migrations (Drizzle in mybooks's
#      preflight, knex in connect's entrypoint, knex in tb's entrypoint,
#      MIGRATE_ON_BOOT in payroll) forward-migrate any older schema in
#      the snapshot — restoring a NEWER backup onto an OLDER image is
#      not supported.
apps_restore() {
    require_root
    local app="${1:-}"
    local tarball="${2:-}"
    [ -n "$app" ] && [ -n "$tarball" ] || die "usage: vibe restore <app> <tarball-path>"
    apps_is_supported "$app" || die "unknown app: $app"
    [ -f "$tarball" ] || die "tarball not found: $tarball"

    log "validating tarball..."
    if ! tar -tzf "$tarball" >/dev/null 2>&1; then
        die "tarball appears corrupted or is not a gzipped tar: $tarball"
    fi
    # GNU tar strips leading slashes when archiving absolute paths, so
    # entries inside the tarball look like `var/lib/vibe/<app>/...` and
    # `etc/vibe/<app>/...`. Both should be present for a well-formed
    # apps_backup snapshot; missing either makes the restore incomplete
    # (we warn but continue so the operator can recover from a partial
    # backup if they really mean to).
    local has_data has_etc
    has_data=0
    has_etc=0
    if tar -tzf "$tarball" 2>/dev/null | grep -q "^var/lib/vibe/${app}/"; then has_data=1; fi
    if tar -tzf "$tarball" 2>/dev/null | grep -q "^etc/vibe/${app}/"; then has_etc=1; fi
    if [ "$has_data" -eq 0 ]; then
        warn "tarball does not contain var/lib/vibe/${app}/ — host-bind data won't be restored"
    fi
    if [ "$has_etc" -eq 0 ]; then
        warn "tarball does not contain etc/vibe/${app}/ — env file + secrets won't be restored"
    fi
    if [ "$has_data" -eq 0 ] && [ "$has_etc" -eq 0 ]; then
        die "tarball contains nothing for ${app} — refusing to wipe current state for an empty restore"
    fi

    # Confirmation. Skipped under VIBE_ASSUME_YES (used by vibed-driven
    # restores from the admin UI — the UI's modal already collected the
    # operator's consent).
    if ! confirm "Restore ${app} from ${tarball}? Existing data will be archived first, then overwritten. [y/N] " no; then
        log "aborted"
        return 1
    fi

    # Stop the app cleanly. Best-effort; if the env file is gone (rare —
    # only happens if the operator already tore everything down by hand)
    # apps_compose dies and we proceed.
    if [ -f "$(secrets_env_path "$app")" ]; then
        log "stopping ${app}..."
        apps_compose "$app" down --remove-orphans 2>/dev/null || true
    fi

    # Pre-restore safety archive — same shape as apps_backup writes,
    # under .archive/ rather than the per-app backups/ dir so the
    # rollback path is grouped with other archived snapshots.
    local ts safety
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 0700 -o "$VIBE_USER" -g "$VIBE_USER" "${VIBE_DATA}/.archive"
    safety="${VIBE_DATA}/.archive/${app}-pre-restore-${ts}.tar.gz"
    if [ -d "${VIBE_DATA}/${app}" ] || [ -d "${VIBE_ETC}/${app}" ]; then
        log "archiving current state → ${safety}"
        local items=()
        [ -d "${VIBE_DATA}/${app}" ] && items+=("${VIBE_DATA}/${app}")
        [ -d "${VIBE_ETC}/${app}" ]  && items+=("${VIBE_ETC}/${app}")
        if ! tar -czf "$safety" "${items[@]}" 2>/dev/null; then
            warn "safety archive write failed — refusing to proceed with the restore"
            return 1
        fi
        chown "$VIBE_USER:$VIBE_USER" "$safety" 2>/dev/null || true
        chmod 0640 "$safety" 2>/dev/null || true
    fi

    # Wipe + extract.
    log "removing current ${app} data at ${VIBE_DATA}/${app}/ and ${VIBE_ETC}/${app}/..."
    rm -rf "${VIBE_DATA}/${app}" "${VIBE_ETC}/${app}"

    log "extracting tarball into /..."
    if ! tar -xzf "$tarball" -C / 2>&1; then
        err "tar extraction failed — appliance may be in a half-restored state"
        warn "rollback: tar -xzf ${safety} -C /"
        return 1
    fi

    # Re-apply per-uid ownership (postgres uid 70, redis uid 999).
    # apps_ensure_datadirs is idempotent so this is a no-op on apps that
    # don't have those special-case dirs.
    apps_ensure_datadirs "$app"

    log "starting ${app}..."
    if ! apps_compose "$app" up -d --remove-orphans; then
        err "${app} failed to start after restore"
        warn "rollback: tar -xzf ${safety} -C /"
        return 1
    fi

    if ! apps_wait_healthy "$app" "$(apps_primary_service "$app")" 240; then
        err "${app} did not become healthy after restore"
        warn "rollback: tar -xzf ${safety} -C /"
        return 1
    fi

    # Add to the installed registry — restoring an app that was previously
    # uninstalled should put it back in the visible set.
    config_installed_add "$app"

    # Reload the ingress so the app's caddy.fragment is in the rendered
    # Caddyfile (necessary if we just re-installed an uninstalled app).
    if [ "$(mode_current)" = "multi" ]; then
        ingress_reload
    fi

    ok "${app} restored from ${tarball}"
    log "pre-restore safety archive: ${safety}"
}

# ---------- Uninstall ----------
# `vibe uninstall <app>` — stop containers, archive volumes + env, remove from
# the installed registry. Volumes are NOT deleted from Docker; they're tarred
# into /var/lib/vibe/.archive/<app>-<timestamp>/ and the named-volume entries
# remain reachable via `docker volume ls` if the operator wants to restore.
apps_uninstall() {
    require_root
    local app="${1:-}"
    if [ "$app" = "--all" ]; then
        apps_uninstall_all
        return $?
    fi
    [ -n "$app" ] || die "usage: vibe uninstall <app>  |  vibe uninstall --all"

    # Integrations have their own uninstall paths and don't touch vibe.conf.
    if apps_is_integration "$app"; then
        case "$app" in
            glm-ocr)   glm_ocr_uninstall ;;
            tailscale) tailscale_uninstall ;;
            tools)     tools_uninstall ;;
        esac
        return $?
    fi

    apps_is_supported "$app" || die "unknown app: $app"
    config_installed_has "$app" || { warn "$app is not installed"; return 0; }

    config_snapshot

    # Same subshell pattern as apps_install: run the destructive workload
    # in a child shell so `die`/`exit` triggers the rollback rather than
    # bypassing it.
    local count_before
    count_before="$(config_installed_count)"

    local rc=0
    ( _apps_uninstall_workload "$app" ) || rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "uninstall of '${app}' failed (rc=${rc}) — rolling back vibe.conf"
        config_restore
        return $rc
    fi

    config_installed_remove "$app"

    # Always-multi: every uninstall just re-renders the Caddyfile so the
    # removed app's tile/route is gone. The ingress keeps running even
    # with zero apps installed — the landing page is still reachable at
    # https://<host>/ and the operator can re-install at any time without
    # rebooting the network shape.
    if [ "$(mode_current)" = "multi" ]; then
        ingress_reload
    elif [ "$count_before" -eq 1 ] && ingress_running; then
        # Legacy: a stray single-app config that still has an ingress
        # running. Don't tear it down; just stop syncing it.
        ingress_reload
    fi

    config_commit
    ok "${app} uninstalled (data archived to ${VIBE_DATA}/.archive/)"
}

# Subshell-launched uninstall workload — see apps_install for the pattern.
_apps_uninstall_workload() {
    local app="$1"
    log "stopping ${app} containers..."
    apps_compose "$app" down --remove-orphans
    apps_archive_data "$app"
    log "removing /etc/vibe/${app}/ ..."
    rm -rf "${VIBE_ETC}/${app}"
}

# Tar-based archive of the per-app on-disk data. For apps that use Docker
# named volumes (TB, Payroll), we also dump them via a one-shot busybox
# container so the archive captures everything restorable.
apps_archive_data() {
    local app="$1"
    require_root
    install -d -m 0700 -o "$VIBE_USER" -g "$VIBE_USER" "${VIBE_DATA}/.archive"
    local ts dest
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    dest="${VIBE_DATA}/.archive/${app}-${ts}"
    install -d -m 0700 -o "$VIBE_USER" -g "$VIBE_USER" "$dest"

    log "archiving ${app} data → ${dest}/"

    # 1. Per-app bind-mount data under /var/lib/vibe/<app>/
    local base="${VIBE_DATA}/${app}"
    if [ -d "$base" ]; then
        ( cd "${VIBE_DATA}" && tar -czf "${dest}/host-data.tar.gz" "${app}/" 2>/dev/null ) \
            && ok "  host-data.tar.gz" \
            || warn "  host-data archive failed"
    fi

    # 2. Per-app env files (env, license-public.pem, postgres_password, etc.)
    if [ -d "${VIBE_ETC}/${app}" ]; then
        ( cd "${VIBE_ETC}" && tar -czf "${dest}/etc.tar.gz" "${app}/" 2>/dev/null ) \
            && ok "  etc.tar.gz" \
            || warn "  etc archive failed"
    fi

    # 3. Docker named volumes belonging to this compose project.
    if has_cmd docker; then
        local vol
        for vol in $(docker volume ls --quiet --filter "label=com.docker.compose.project=vibe-${app}" 2>/dev/null); do
            log "  archiving docker volume ${vol}..."
            docker run --rm \
                -v "${vol}:/source:ro" \
                -v "${dest}:/backup" \
                busybox \
                sh -c "cd /source && tar -czf /backup/${vol}.tar.gz . 2>/dev/null" \
                && ok "    ${vol}.tar.gz" \
                || warn "    ${vol} archive failed"
        done
    fi

    chown -R "$VIBE_USER:$VIBE_USER" "$dest" 2>/dev/null || true
    ok "archived to ${dest}/"
}

# `vibe uninstall --all` — tear down every app + the ingress.
apps_uninstall_all() {
    require_root
    local apps
    apps="$(config_installed_list)"
    if [ -z "$apps" ] && ! ingress_running; then
        ok "nothing installed"
        return 0
    fi

    warn "This will stop every Vibe app, archive all data, and clear /etc/vibe/<app>/."
    warn "Volumes are tarred into ${VIBE_DATA}/.archive/ and not deleted from Docker."
    if ! confirm "Continue? [y/N] " no; then
        log "aborted"; return 1
    fi

    local app
    for app in $apps; do
        apps_uninstall "$app" || warn "uninstall of $app returned non-zero"
    done

    if ingress_running; then
        ingress_down
    fi

    ok "all apps uninstalled — installer + Docker themselves remain"
    log "to remove Docker and the vibe user, run: sudo /opt/vibe-installer/uninstall.sh"
}

# ---------- logs / exec / backup ----------
apps_logs() {
    require_root
    local app="${1:-}"
    [ -n "$app" ] || die "usage: vibe logs <app> [service]"
    apps_is_supported "$app" || die "unknown app: $app"
    config_installed_has "$app" || die "$app is not installed"
    shift
    local service="${1:-}"
    if [ -n "$service" ]; then
        apps_compose "$app" logs --tail 200 --follow "$service"
    else
        apps_compose "$app" logs --tail 200 --follow
    fi
}

apps_exec() {
    require_root
    local app="${1:-}" service="${2:-}"
    [ -n "$app" ] && [ -n "$service" ] || die "usage: vibe exec <app> <service> <cmd> [args...]"
    apps_is_supported "$app" || die "unknown app: $app"
    config_installed_has "$app" || die "$app is not installed"
    shift 2
    apps_compose "$app" exec "$service" "$@"
}

# `vibe backup <app>` — best-effort tarball of an app's volumes. Drops a
# timestamped archive under /var/lib/vibe/<app>/backups/. Operators with a
# Duplicati setup will use that for off-host replication; this command is
# the fallback for "I just need a snapshot right now."
apps_backup() {
    require_root
    local app="${1:-}"
    [ -n "$app" ] || die "usage: vibe backup <app>"
    apps_is_supported "$app" || die "unknown app: $app"
    config_installed_has "$app" || die "$app is not installed"

    local base="${VIBE_DATA}/${app}"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "${base}/backups"
    local ts out
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    out="${base}/backups/snapshot-${ts}.tar.gz"

    log "snapshotting ${app} → ${out}"
    # Lightweight: tar the host-bind data dir + env. Named volumes are best
    # captured via apps_archive_data (which uninstall calls); for ad-hoc
    # backups operators of TB/Payroll should use Duplicati against the named
    # volume mountpoint.
    local items=()
    [ -d "${VIBE_DATA}/${app}" ]   && items+=("${VIBE_DATA}/${app}")
    [ -d "${VIBE_ETC}/${app}" ]    && items+=("${VIBE_ETC}/${app}")
    if [ "${#items[@]}" -eq 0 ]; then
        warn "no on-disk data to back up — try Duplicati for named-volume apps (tb/payroll)"
        return 1
    fi
    tar -czf "$out" "${items[@]}" 2>/dev/null \
        || die "tar failed (check that ${VIBE_USER} can read every path)"
    chown "$VIBE_USER:$VIBE_USER" "$out"
    chmod 0640 "$out"
    ok "backup: $out ($(du -h "$out" | cut -f1))"
}

apps_status_line() {
    local app="$1"
    if ! config_installed_has "$app"; then
        printf '  %-10s %s\n' "$app" "not installed"
        return
    fi
    local key version
    key="$(apps_version_key "$app")"
    version="$(secrets_get "$app" "$key" 2>/dev/null || true)"
    [ -z "$version" ] && version="(unpinned)"
    if has_cmd docker; then
        local up_count
        up_count="$(apps_compose "$app" ps -q 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
        printf '  %-10s version=%s  containers=%s\n' "$app" "$version" "$up_count"
    else
        printf '  %-10s version=%s\n' "$app" "$version"
    fi
}
