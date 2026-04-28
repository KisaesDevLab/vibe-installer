#!/usr/bin/env bash
# Cloudflare Tunnel toggle — per-app, customer-owned token.
#
# Each app's docker-compose.yml ships a `cloudflared` service under
#   profiles: ["tunnel"]   (MyBooks, Connect)
#   profiles: ["cloudflare"]  (Payroll — uses a different name)
#
# The installer normalizes both via a per-app profile name in
# cloudflare_profile_name. Token comes from the firm's own Cloudflare Zero
# Trust dashboard; the installer never embeds Kisaes credentials.
#
# install.sh::prompt_tls_intent stashes the token at /etc/vibe/cloudflared/
# tunnel.token (mode 0600) so it can be picked up later by `vibe install
# <app>` without the operator having to paste it again. cloudflare_load_
# stashed_token reads + clears that file once it's been applied to a
# specific app's env so it can't be reused by mistake.
#
# common.sh + secrets.sh + apps.sh sourced by callers.

# Where install.sh stashed the operator-supplied tunnel token. Path is
# relative to VIBE_ETC so a non-default install location stays consistent.
cloudflare_token_stash_path() {
    printf '%s/cloudflared/tunnel.token\n' "${VIBE_ETC}"
}

# Read the stashed token if present. Returns empty string + non-zero status
# when no stash exists. Caller is responsible for calling
# cloudflare_clear_stashed_token after the token's been applied to an app
# so a second `vibe install <app>` doesn't silently reuse the same token.
cloudflare_read_stashed_token() {
    local path
    path="$(cloudflare_token_stash_path)"
    [ -f "$path" ] || return 1
    cat "$path"
}

# Best-effort delete of the stash. Owner is `vibe`, but the caller may be
# either root (vibe install runs require_root) or the vibe user itself —
# so we don't fail if the unlink can't happen. The dangerous case is leaving
# the file behind, not failing to delete it (mode 0600 already protects it).
cloudflare_clear_stashed_token() {
    local path
    path="$(cloudflare_token_stash_path)"
    [ -f "$path" ] || return 0
    rm -f "$path" 2>/dev/null || warn "couldn't delete stashed token at $path — please remove it manually"
}

# Per-app Compose profile that activates the cloudflared sidecar.
cloudflare_profile_name() {
    case "$1" in
        payroll) printf 'cloudflare\n' ;;
        *)       printf 'tunnel\n' ;;
    esac
}

# Apps that ship a cloudflared service today. TB is omitted because its
# upstream prod compose has no cloudflared sidecar yet — `vibe cloudflare
# attach tb` will be a no-op until that lands.
cloudflare_supported() {
    local app="$1"
    case "$app" in
        mybooks|connect|payroll) return 0 ;;
        *)                       return 1 ;;
    esac
}

# Redact a Cloudflare token for log output. Keeps the leading 8 chars and
# the trailing 4 — enough for the operator to identify the token without
# exposing it in scrollback.
cloudflare_redact() {
    local t="$1"
    local n=${#t}
    if [ "$n" -lt 16 ]; then
        printf '<redacted>\n'
    else
        printf '%s…%s\n' "${t:0:8}" "${t: -4}"
    fi
}

# `vibe cloudflare attach <app> --token <token>` (or with token on stdin).
cloudflare_attach() {
    require_root
    local app="${1:-}"
    [ -n "$app" ] || die "usage: vibe cloudflare attach <app> --token <token>"
    apps_is_supported "$app" || die "unknown app: $app"
    cloudflare_supported "$app" || die "cloudflare tunnel not supported for $app yet"
    config_installed_has "$app" || die "$app is not installed"
    shift

    local token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --token) token="${2:-}"; shift 2 ;;
            *) warn "ignoring unknown flag: $1"; shift ;;
        esac
    done

    if [ -z "$token" ] && [ ! -t 0 ]; then
        # Token piped in on stdin (e.g. via cat secret | vibe cloudflare attach <app>)
        token="$(cat)"
    elif [ -z "$token" ] && [ -t 0 ]; then
        echo
        echo "  Paste your Cloudflare tunnel token (one line, from"
        echo "  Zero Trust → Networks → Tunnels → <tunnel> → Install"
        echo "  connector → copy everything AFTER --token):"
        read -rsp "  Token: " token
        echo
    fi

    [ -n "$token" ] || die "no token supplied"

    log "attaching Cloudflare tunnel to ${app} (token $(cloudflare_redact "$token"))"

    secrets_set "$app" CLOUDFLARE_TUNNEL_TOKEN "$token"

    local profile
    profile="$(cloudflare_profile_name "$app")"

    log "starting cloudflared sidecar for ${app}..."
    apps_compose "$app" --profile "$profile" up -d cloudflared || {
        err "failed to start cloudflared sidecar"
        warn "check token validity at https://one.dash.cloudflare.com/"
        return 1
    }
    ok "cloudflare: ${app} is now reachable via the tunnel"
    echo
    log "Verify with:"
    if [ "$(mode_current)" = "multi" ]; then
        log "  curl -fsS https://<tunnel-hostname>/${app}/health"
    else
        log "  curl -fsS https://<tunnel-hostname>/health"
    fi
    log "  vibe logs ${app} cloudflared"
}

cloudflare_detach() {
    require_root
    local app="${1:-}"
    [ -n "$app" ] || die "usage: vibe cloudflare detach <app>"
    apps_is_supported "$app" || die "unknown app: $app"
    cloudflare_supported "$app" || { ok "no cloudflared sidecar for $app — nothing to detach"; return 0; }
    config_installed_has "$app" || die "$app is not installed"

    local profile
    profile="$(cloudflare_profile_name "$app")"

    log "stopping cloudflared sidecar for ${app}..."
    apps_compose "$app" --profile "$profile" stop cloudflared 2>/dev/null || true
    apps_compose "$app" --profile "$profile" rm -f cloudflared 2>/dev/null || true

    # Clear the token from the env file so a future `up` without --profile
    # tunnel doesn't accidentally start the sidecar with a stale token.
    secrets_set "$app" CLOUDFLARE_TUNNEL_TOKEN ""
    ok "cloudflare: detached ${app}"
}

cloudflare_status() {
    local app="${1:-}"
    if [ -n "$app" ]; then
        apps_is_supported "$app" || die "unknown app: $app"
        local token
        token="$(secrets_get "$app" CLOUDFLARE_TUNNEL_TOKEN 2>/dev/null || true)"
        if [ -n "$token" ]; then
            printf '  %-10s attached (token %s)\n' "$app" "$(cloudflare_redact "$token")"
        else
            printf '  %-10s not attached\n' "$app"
        fi
        return 0
    fi
    log "Cloudflare tunnel status:"
    local a
    for a in $APPS_SUPPORTED; do
        cloudflare_supported "$a" || continue
        config_installed_has "$a" || continue
        cloudflare_status "$a"
    done
}
