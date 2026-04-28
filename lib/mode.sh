#!/usr/bin/env bash
# Mode switching: single-app ↔ multi-app transitions.
#
# As of the always-multi-app switch, every new install lands in multi-app
# mode immediately and stays there forever — URLs are stable from day one,
# adding or removing apps never moves them. The single-app shape is kept
# only for:
#
#   * Legacy /etc/vibe/vibe.conf files written before the always-multi
#     switch (migrated automatically on first `vibe` invocation via
#     mode_migrate_to_always_multi).
#   * Developer convenience — running `docker compose up -d` directly in
#     apps/<name>/ without layering the grouped overlay still publishes
#     host ports.
#
# The legacy promotion / demotion paths below are preserved so the
# migration path can reuse them and so old fixtures keep working in CI.
#
# common.sh + config.sh + apps.sh + ingress.sh sourced by callers.

# ---------- Detection helpers ----------
mode_current() {
    config_get mode
}

mode_should_be_multi() {
    [ "$(config_installed_count)" -ge 2 ]
}

# ---------- 1 → 2 promotion ----------
# Caller passes the list of currently-installed apps (BEFORE adding the new one).
# After this returns, the caller is expected to bring up the new app on its
# own using apps_compose (which picks the right overlay from mode=multi).
mode_promote_to_multi() {
    require_root
    local current_apps=("$@")
    local cur="$(mode_current)"
    if [ "$cur" = "multi" ]; then
        ok "already in multi-app mode"
        return 0
    fi

    log "promoting host to multi-app mode (Caddy ingress at https://$(config_get host)/)..."

    # 1. Tear down the existing apps WITHOUT the grouped overlay so the
    #    base compose's ports-published shape comes down cleanly. Volumes
    #    are preserved (compose down keeps named volumes by default).
    local app
    for app in "${current_apps[@]}"; do
        log "  stopping ${app} (single-app shape)..."
        # Force single-app mode for the down call so apps_compose doesn't
        # try to layer the grouped overlay against a not-yet-multi state.
        ( config_set mode single
          apps_compose "$app" down --remove-orphans
        ) || warn "down for ${app} returned non-zero — continuing"
    done

    # 2. Mark mode=multi so subsequent apps_compose calls layer the overlay.
    config_set mode multi

    # 3. Bring up the Caddy ingress.
    ingress_up

    # 4. Re-up the existing apps in the grouped (multi) shape.
    for app in "${current_apps[@]}"; do
        log "  re-up ${app} in multi-app shape..."
        apps_compose "$app" up -d --remove-orphans
    done

    # 5. Trust the local CA if applicable (no-op on acme / cf-tunnel).
    ingress_trust_local_ca

    ok "host is now in multi-app mode"
}

# ---------- 2 → 1 demotion ----------
# Caller passes the surviving app (the one that wasn't uninstalled).
mode_demote_to_single() {
    require_root
    local survivor="$1"
    local cur="$(mode_current)"
    if [ "$cur" = "single" ]; then
        ok "already in single-app mode"
        return 0
    fi
    [ -n "$survivor" ] || die "mode_demote_to_single requires the surviving app name"

    log "demoting host to single-app mode (only '${survivor}' will remain installed)..."

    # 1. Stop the survivor in its multi-app shape.
    apps_compose "$survivor" down --remove-orphans || warn "down for ${survivor} returned non-zero"

    # 2. Tear down the ingress.
    ingress_down

    # 3. Mark mode=single so the next apps_compose call drops the grouped overlay.
    config_set mode single

    # 4. Re-up the survivor in single-app shape.
    apps_compose "$survivor" up -d --remove-orphans

    ok "host is now in single-app mode (only ${survivor} installed)"
}

# ---------- Forced transitions (`vibe mode <single|multi>`) ----------
# Used by the operator to flip the host between modes WITHOUT installing or
# uninstalling an app. Also called by install.sh during bootstrap to make
# sure the ingress is up before the first app install — even on a freshly-
# installed host with zero apps, `vibe mode multi` brings Caddy up so the
# landing page is reachable from the moment install.sh exits.
mode_force() {
    require_root
    local target="$1"
    local cur="$(mode_current)"
    [ -n "$target" ] || die "usage: vibe mode <single|multi>"
    case "$target" in single|multi) ;; *) die "mode must be single or multi" ;; esac

    local installed
    installed="$(config_installed_list)"

    # Set mode if changing — cheap, harmless to re-set the same value.
    if [ "$cur" != "$target" ]; then
        config_set mode "$target"
        ok "mode changed to ${target}"
    fi

    # `vibe mode multi` is the canonical "make the ingress reflect current
    # vibe.conf" command. install.sh relies on this — when render_config
    # back-fills a new field (e.g. host_ip after the IP-SAN fix), the
    # subsequent `vibe mode multi` call needs to RE-RENDER the Caddyfile
    # AND signal Caddy to pick up the change. Short-circuiting here on
    # "mode is already multi" was a real bug: Caddy kept serving a stale
    # cert because the Caddyfile on disk hadn't moved.
    if [ "$target" = "multi" ]; then
        if ingress_running; then
            ingress_reload   # re-renders + SIGHUPs
        else
            ingress_up
            ingress_trust_local_ca
        fi
        ok "ingress is reflecting current ${VIBE_CONF}"
        return 0
    fi

    # target=single from here. If we were already single, nothing to do
    # other than (no-op-ly) confirm.
    if [ -z "$installed" ]; then
        if [ "$cur" = "$target" ]; then
            ok "mode is already single (no apps installed)"
        fi
        return 0
    fi

    if [ "$target" = "$cur" ]; then
        ok "mode is already ${cur}"
        return 0
    fi

    # target=single, currently multi, with apps installed. Only allow
    # demotion when exactly one app remains; otherwise the operator must
    # uninstall first.
    local count
    count=$(printf '%s\n' "$installed" | wc -l | tr -d ' ')
    if [ "$count" -ne 1 ]; then
        die "cannot force single mode with ${count} apps installed; uninstall first"
    fi
    mode_demote_to_single "$installed"
}

# ---------- Migration: legacy single → always-multi ----------
# Called from bin/vibe at startup. A pre-existing /etc/vibe/vibe.conf with
# mode=single was written before the always-multi switch. We migrate it on
# the next vibe invocation so the operator's URLs become stable. If apps
# are installed in single-app shape we walk them through the same
# promotion machinery the legacy 1→2 transition used. If no apps are
# installed yet we just flip the mode value and (on a root invocation)
# bring the ingress up.
mode_migrate_to_always_multi() {
    [ -f "$VIBE_CONF" ] || return 0
    local cur
    cur="$(mode_current)"
    [ "$cur" = "single" ] || return 0

    local installed_count
    installed_count="$(config_installed_count)"

    if [ "$(id -u)" -ne 0 ]; then
        # We can't migrate without root (it brings up containers). Just
        # warn so the operator knows what's pending — actual migration
        # happens on their next sudo invocation.
        warn "legacy mode=single detected — run 'sudo vibe mode multi' to migrate"
        return 0
    fi

    if [ "$installed_count" -eq 0 ]; then
        log "migrating legacy mode=single → multi (no apps installed)"
        config_set mode multi
        if ! ingress_running; then
            ingress_up
            ingress_trust_local_ca
        fi
        ok "migration complete"
        return 0
    fi

    log "migrating legacy mode=single → multi (${installed_count} app(s) installed)"
    log "  apps will be briefly stopped and restarted under the Caddy ingress"
    log "  URLs change from per-app ports to https://$(config_get host)/<app>/"
    local apps=()
    while IFS= read -r a; do apps+=("$a"); done < <(config_installed_list)
    mode_promote_to_multi "${apps[@]}"
    ok "migration complete — bookmarks must be updated to the new https://<host>/<app>/ URLs"
}
