#!/usr/bin/env bash
# `vibe upgrade-check` — manual, read-only check for newer GHCR tags.
# No background timer, no auto-apply (per the user's manual-update preference).
#
# For each installed Vibe app, ask GHCR for the list of tags, compare against
# the currently pinned IMAGE_TAG / VIBE_*_VERSION, and report newer minor
# versions. Operator decides whether to run `vibe upgrade <app> --to <ver>`.

# Per-app GHCR repo path used to fetch tag lists. Apps with two
# images (api + web) check just the api leg — the release.yml
# workflows publish both legs in lockstep off the same git tag, so a
# newer api implies a newer web in practice.
update_check_image() {
    case "$1" in
        mybooks) printf 'kisaesdevlab/vibe-mybooks-api\n' ;;
        connect) printf 'kisaesdevlab/vibe-connect\n' ;;
        tb)      printf 'kisaesdevlab/vibe-tb-api\n' ;;
        payroll) printf 'kisaesdevlab/vibe-payroll-api\n' ;;
        tax)     printf 'kisaesdevlab/vibe-tax-api\n' ;;
        admin)   printf 'kisaesdevlab/vibe-admin\n' ;;
    esac
}

# GHCR token-less anonymous tag listing. Returns one tag per line on stdout
# or empty if anonymous read isn't permitted (the operator will see a
# warning instead of a list).
update_check_tags() {
    local image="$1"
    require_cmd curl
    local token resp
    # Anonymous read works for public packages via a service token.
    token="$(curl -fsS --max-time 10 \
        "https://ghcr.io/token?scope=repository:${image}:pull" \
        2>/dev/null | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)"
    [ -n "$token" ] || return 1
    resp="$(curl -fsS --max-time 10 \
        -H "Authorization: Bearer ${token}" \
        "https://ghcr.io/v2/${image}/tags/list" 2>/dev/null)"
    [ -n "$resp" ] || return 1
    printf '%s' "$resp" | grep -o '"tags":\[[^]]*\]' \
        | tr ',' '\n' | grep -o '"[^"]*"' | tr -d '"'
}

# Filter tags for "looks like a release" — semver-ish, exclude latest/dev.
update_check_release_tags() {
    grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || true
}

# Compare two semver-ish strings; echoes "newer" if $2 > $1, "equal" if ==,
# "older" otherwise. Treats missing patch as 0.
update_check_compare() {
    local a="$1" b="$2"
    local IFS=. va=($a) vb=($b)
    for i in 0 1 2; do
        local na=${va[$i]:-0} nb=${vb[$i]:-0}
        if [ "$nb" -gt "$na" ]; then printf 'newer\n'; return; fi
        if [ "$nb" -lt "$na" ]; then printf 'older\n'; return; fi
    done
    printf 'equal\n'
}

update_check_run() {
    local apps
    apps="$(config_installed_list)"
    if [ -z "$apps" ]; then
        log "no apps installed — nothing to check"
        return 0
    fi

    local app
    for app in $apps; do
        local image current key
        image="$(update_check_image "$app")"
        key="$(apps_version_key "$app")"
        current="$(secrets_get "$app" "$key" 2>/dev/null || echo latest)"

        if [ -z "$image" ]; then
            printf '  %-10s (no GHCR repo registered)\n' "$app"
            continue
        fi

        local tags
        if ! tags="$(update_check_tags "$image" | update_check_release_tags | sort -uV)"; then
            printf '  %-10s (could not query ghcr.io — offline?)\n' "$app"
            continue
        fi
        if [ -z "$tags" ]; then
            printf '  %-10s (no release tags published)\n' "$app"
            continue
        fi

        local latest
        latest="$(printf '%s\n' "$tags" | tail -1)"

        if [ "$current" = "latest" ] || [ -z "$current" ]; then
            printf '  %-10s pinned=latest, newest published=%s\n' "$app" "$latest"
            continue
        fi

        local cmp
        cmp="$(update_check_compare "$current" "$latest")"
        case "$cmp" in
            newer) printf '  %-10s pinned=%-12s newer available: %s   (vibe upgrade %s --to %s)\n' \
                       "$app" "$current" "$latest" "$app" "$latest" ;;
            equal) printf '  %-10s pinned=%s (up to date)\n' "$app" "$current" ;;
            older) printf '  %-10s pinned=%s (newer than published latest %s — local override?)\n' \
                       "$app" "$current" "$latest" ;;
        esac
    done
}

# Same probe as update_check_run, but emits JSON to stdout instead of
# the human-formatted table. The output is a single JSON object whose
# `apps` key holds an array of:
#
#   {
#     "app":       "mybooks",
#     "current":   "1.4.0" | "latest" | "",
#     "latest":    "1.5.2" | "",
#     "all_tags":  ["1.4.0", "1.5.0", "1.5.2"],
#     "status":    "outdated" | "current" | "unpinned" | "ahead"
#                  | "no-ghcr" | "offline" | "no-tags",
#     "recommended_command": "vibe upgrade mybooks --to 1.5.2" | ""
#   }
#
# (The comment above is the contract `vibed`'s handleAppsUpgradeCheck
# consumes; keep field names in sync with handlers.go's struct.)
update_check_run_json() {
    local apps app first=1
    apps="$(config_installed_list)"
    printf '{"apps":['

    # Emit one entry per installed product app.
    for app in $apps; do
        if [ "$first" -eq 0 ]; then printf ','; fi
        first=0
        _update_check_emit_app_json "$app"
    done

    # Always emit an admin entry. The system admin app isn't in the
    # `installed=` list (it's bootstrap-installed by install.sh) but
    # still shows up in the operator's Updates view because admin
    # self-upgrade is a real ergonomic flow. Skip if /etc/vibe/admin/.env
    # is missing (e.g. the operator never finished bootstrap).
    if [ -f "${VIBE_ETC}/admin/.env" ]; then
        if [ "$first" -eq 0 ]; then printf ','; fi
        first=0
        _update_check_emit_app_json admin
    fi

    printf ']}\n'
}

# Emit one JSON object describing the upgrade-check state of a single
# app. Output has no leading/trailing whitespace and no terminator —
# the caller is responsible for inserting commas between entries.
# Shape matches handlers.go's upgradeCheckApp struct exactly.
_update_check_emit_app_json() {
    local app="$1"
    local image current key tags latest cmp status command
    image="$(update_check_image "$app")"
    key="$(apps_version_key "$app")"
    current="$(secrets_get "$app" "$key" 2>/dev/null || echo latest)"
    latest=""
    tags=""
    status="unknown"
    command=""

    if [ -z "$image" ]; then
        status="no-ghcr"
    elif ! tags="$(update_check_tags "$image" | update_check_release_tags | sort -uV)" \
         || [ -z "$tags" ]; then
        # Conflate "ghcr unreachable" and "no published release tags"
        # under offline because the SPA renders them the same way:
        # "we couldn't tell". Operators can always check by hand.
        status="offline"
    else
        latest="$(printf '%s\n' "$tags" | tail -1)"
        if [ "$current" = "latest" ] || [ -z "$current" ]; then
            status="unpinned"
        else
            cmp="$(update_check_compare "$current" "$latest")"
            case "$cmp" in
                newer) status="outdated"; command="vibe upgrade ${app} --to ${latest}" ;;
                equal) status="current" ;;
                older) status="ahead" ;;
            esac
        fi
    fi

    # Build the all_tags JSON array. tags is newline-separated;
    # update_check_release_tags filters to `^[0-9.]+$` upstream so the
    # strings can't contain a quote, backslash, or control character.
    # Plain printf without jq escaping is fine.
    local tag_json="[" tag_first=1 tag
    if [ -n "$tags" ]; then
        while IFS= read -r tag; do
            [ -z "$tag" ] && continue
            if [ "$tag_first" -eq 0 ]; then tag_json+=","; fi
            tag_json+="\"${tag}\""
            tag_first=0
        done <<< "$tags"
    fi
    tag_json+="]"

    printf '{"app":"%s","current":"%s","latest":"%s","all_tags":%s,"status":"%s","recommended_command":"%s"}' \
        "$app" "$current" "$latest" "$tag_json" "$status" "$command"
}
