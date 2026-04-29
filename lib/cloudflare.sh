#!/usr/bin/env bash
# Cloudflare Tunnel toggle — single ingress-level tunnel, customer-owned token.
#
# Lives in ingress/docker-compose.yml as a profile-gated `cloudflared` service
# under `profiles: [tunnel]`. lib/ingress.sh::ingress_compose auto-passes
# `--profile tunnel` when vibe.conf has tls_mode=cf-tunnel, so the sidecar
# follows the rest of the ingress lifecycle (up/down/reload) without any
# per-app wiring.
#
# The token comes from the firm's own Cloudflare Zero Trust dashboard;
# the installer never embeds Kisaes credentials.
#
# install.sh::prompt_tls_intent stashes the token at /etc/vibe/cloudflared/
# tunnel.token (mode 0600). lib/ingress.sh::ingress_render_envfile reads it
# on every render and exports it as TUNNEL_TOKEN in the ingress's .env so
# compose can interpolate it into the cloudflared command.
#
# Per-app `vibe cloudflare attach <app>` / `detach <app>` — gone. The
# previous model spun up one cloudflared per app, with no central health,
# no aggregation, and a broken story for apps that didn't ship a sidecar
# (TB, Tax). The single-ingress model replaces all of that.
#
# common.sh + secrets.sh + apps.sh sourced by callers.

# Where install.sh stashed the operator-supplied tunnel token.
cloudflare_token_stash_path() {
    printf '%s/cloudflared/tunnel.token\n' "${VIBE_ETC}"
}

# Persist a token to the stash. install.sh's stash_cloudflare_token mirrors
# this — kept here too so `vibe cloudflare set-token` doesn't have to shell
# out to install.sh.
cloudflare_stash_token() {
    require_root
    local token="$1"
    [ -n "$token" ] || die "cloudflare_stash_token: empty token"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "${VIBE_ETC}/cloudflared"
    # No trailing newline — cloudflared trims aren't always reliable, and a
    # trailing \n can make the token look malformed in the dashboard.
    printf '%s' "$token" > "$(cloudflare_token_stash_path)"
    chown "$VIBE_USER:$VIBE_USER" "$(cloudflare_token_stash_path)"
    chmod 0600 "$(cloudflare_token_stash_path)"
}

cloudflare_clear_stash() {
    require_root
    local path
    path="$(cloudflare_token_stash_path)"
    [ -f "$path" ] || { ok "no tunnel token stashed"; return 0; }
    rm -f "$path"
    ok "tunnel token cleared from $path"
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

# `vibe cloudflare set-token [<token>]` — stash a new token + re-render the
# ingress envfile + reload the ingress so the cloudflared sidecar picks up
# the change. Token via $1, --token, or stdin (in that order). Requires
# tls_mode=cf-tunnel — refuses on other modes so the operator gets a clear
# error rather than a token written to disk that nothing reads.
cloudflare_set_token() {
    require_root
    local token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --token) token="${2:-}"; shift 2 ;;
            -*)      warn "ignoring unknown flag: $1"; shift ;;
            *)       token="$1"; shift ;;
        esac
    done
    if [ -z "$token" ] && [ ! -t 0 ]; then
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

    local mode
    mode="$(config_get tls_mode 2>/dev/null || true)"
    if [ "$mode" != "cf-tunnel" ]; then
        warn "current tls_mode=${mode:-unset} — token will be stashed but the"
        warn "cloudflared sidecar only runs when tls_mode=cf-tunnel. Switch with"
        warn "  sudo vibe ingress mode cf-tunnel    (not yet implemented — for"
        warn "  now, re-run install.sh and choose option 3)"
    fi

    cloudflare_stash_token "$token"
    ok "tunnel token stashed (token $(cloudflare_redact "$token"))"

    # Re-render the env file so TUNNEL_TOKEN gets the new value, then reload
    # the ingress (no-op if the ingress isn't running yet).
    ingress_render_envfile
    if ingress_running; then
        log "reloading ingress to pick up new tunnel token..."
        ingress_compose up -d --remove-orphans
        ok "cloudflared sidecar restarted with new token"
    else
        ok "stashed; bring the ingress up with 'sudo vibe mode multi' to start the tunnel"
    fi
}

# `vibe cloudflare status` — show whether tls_mode=cf-tunnel, whether a
# token is stashed, and whether the cloudflared sidecar is running.
cloudflare_status() {
    local mode token has_stash="no" sidecar="not running"
    mode="$(config_get tls_mode 2>/dev/null || true)"
    if [ -f "$(cloudflare_token_stash_path)" ]; then
        has_stash="yes"
        token="$(cat "$(cloudflare_token_stash_path)")"
    fi
    if docker ps --filter 'name=^vibe-ingress-cloudflared$' --format '{{.Names}}' 2>/dev/null \
            | grep -qx vibe-ingress-cloudflared; then
        sidecar="running"
    fi
    log "Cloudflare tunnel:"
    printf '  tls_mode    %s\n' "${mode:-unset}"
    printf '  stash       %s' "$has_stash"
    if [ "$has_stash" = "yes" ]; then
        printf ' (token %s)' "$(cloudflare_redact "$token")"
    fi
    echo
    printf '  sidecar     %s\n' "$sidecar"
}

# `vibe cloudflare logs` — tail the ingress-level cloudflared sidecar logs.
cloudflare_logs() {
    if ! docker ps --filter 'name=^vibe-ingress-cloudflared$' --format '{{.Names}}' 2>/dev/null \
            | grep -qx vibe-ingress-cloudflared; then
        die "cloudflared sidecar isn't running (tls_mode=$(config_get tls_mode 2>/dev/null))"
    fi
    docker logs -f --tail=100 vibe-ingress-cloudflared
}

# ---------- Deprecation shims ----------
#
# The pre-2026-04 model had `vibe cloudflare attach <app>` / `detach <app>`
# spinning up one cloudflared per app. That's gone — the ingress owns the
# tunnel now. Keep the verbs as friendly redirects so muscle memory still
# works.

cloudflare_attach() {
    local app="${1:-}"
    if [ -n "$app" ]; then
        warn "'vibe cloudflare attach <app>' is deprecated — the ingress now"
        warn "owns a single tunnel for every app. To set the token, use:"
        warn "  sudo vibe cloudflare set-token [<token>]"
    fi
    # Forward any --token argument to set-token so old callers keep working.
    shift || true
    cloudflare_set_token "$@"
}

cloudflare_detach() {
    warn "'vibe cloudflare detach <app>' is deprecated — the tunnel is per-ingress"
    warn "now, not per-app. To stop tunneling entirely, clear the token and"
    warn "switch tls_mode away from cf-tunnel:"
    warn "  sudo vibe cloudflare clear"
    warn "  sudo vibe ingress mode internal     (re-run install.sh to switch modes)"
    return 1
}
