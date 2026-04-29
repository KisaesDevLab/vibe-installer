#!/usr/bin/env bash
# License public-key + token management.
#
# Per-product keys: GET https://licensing.kisaes.com/v1/public-key?app=<app>
# Trial fallback: POST https://licensing.kisaes.com/v1/trial { app, host_id }
# License token order of preference (license_activate <app>):
#   1. VIBE_LICENSE_TOKEN_<APP> env var (unattended path)
#   2. Interactive prompt if TTY present
#   3. Trial fallback (auto, no prompt) — 30-day RSA-signed token
#
# common.sh + secrets.sh sourced by callers.

VIBE_LICENSE_SERVER="${VIBE_LICENSE_SERVER:-https://licensing.kisaes.com}"
VIBE_LICENSE_PUBKEY_TTL="${VIBE_LICENSE_PUBKEY_TTL:-86400}"   # 24h

# ---------- Per-app pubkey path ----------
license_pubkey_path() {
    local app="$1"
    printf '%s\n' "${VIBE_ETC}/${app}/license-public.pem"
}

# ---------- Fetch & cache the per-product RSA public key ----------
# Returns 0 on cache hit OR fresh fetch; non-zero only if both fail.
license_fetch_pubkey() {
    local app="$1"
    require_root
    secrets_ensure_envdir "$app"
    local pem
    pem="$(license_pubkey_path "$app")"

    # Cache hit: pem is non-empty and younger than TTL.
    if [ -s "$pem" ]; then
        local age now mtime
        now="$(date +%s)"
        mtime="$(stat -c %Y "$pem" 2>/dev/null || echo 0)"
        age=$((now - mtime))
        if [ "$age" -lt "$VIBE_LICENSE_PUBKEY_TTL" ]; then
            dbg "license: pubkey cache hit ($pem, age ${age}s)"
            return 0
        fi
    fi

    if ! has_cmd curl; then
        warn "license: curl missing — cannot refresh pubkey for $app"
        [ -s "$pem" ] && return 0 || return 1
    fi

    log "fetching license pubkey for ${app} from ${VIBE_LICENSE_SERVER}..."
    local tmp
    tmp="$(mktemp "${pem}.XXXXXX")"
    # Try per-product first (server-side support for ?app= is incoming);
    # fall back to the shared key endpoint if 404 / not implemented.
    if ! curl -fsSL --max-time 30 \
            "${VIBE_LICENSE_SERVER}/v1/public-key?app=${app}" \
            -o "$tmp" 2>/dev/null; then
        dbg "license: ?app=${app} not honored, falling back to shared /v1/public-key"
        if ! curl -fsSL --max-time 30 \
                "${VIBE_LICENSE_SERVER}/v1/public-key" \
                -o "$tmp"; then
            rm -f "$tmp"
            if [ -s "$pem" ]; then
                warn "license: pubkey fetch failed; using stale cache (${pem})"
                return 0
            fi
            warn "license: pubkey fetch failed and no cache — license check will fail"
            return 1
        fi
    fi

    # Sanity-check it parses as an RSA pubkey.
    if ! openssl rsa -pubin -in "$tmp" -noout >/dev/null 2>&1 \
       && ! openssl pkey -pubin -in "$tmp" -noout >/dev/null 2>&1; then
        rm -f "$tmp"
        err "license: server returned a value that doesn't parse as a public key"
        return 1
    fi

    chown "$VIBE_USER:$VIBE_USER" "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$pem"
    config_set license_pubkey_fetched_at "$(date +%s)"
    ok "license: cached pubkey at $pem"
}

# ---------- Trial fallback ----------
# Asks the license server for a 30-day trial token bound to this host.
license_request_trial() {
    local app="$1"
    require_cmd curl
    require_cmd jq
    local body resp token host_id
    host_id="$(machine_id)"
    body="$(jq -nc --arg app "$app" --arg hid "$host_id" '{app:$app, host_id:$hid}')"
    log "requesting 30-day trial token for ${app}..."
    if ! resp="$(curl -fsS --max-time 30 \
            -H 'content-type: application/json' \
            -d "$body" \
            "${VIBE_LICENSE_SERVER}/v1/trial" 2>/dev/null)"; then
        warn "license: trial request failed (offline? license server down?)"
        return 1
    fi
    token="$(printf '%s' "$resp" | jq -r '.token // empty')"
    if [ -z "$token" ]; then
        warn "license: trial response missing .token field"
        return 1
    fi
    printf '%s\n' "$token"
}

# ---------- Activation flow ----------
# Writes LICENSE_TOKEN + DISABLE_LICENSE_CHECK=0 into the app's env file.
# Idempotent: if a non-empty LICENSE_TOKEN already exists, leaves it.
license_activate() {
    local app="$1"
    require_root

    # Already activated?
    local current
    current="$(secrets_get "$app" LICENSE_TOKEN)"
    if [ -n "$current" ] && [ "$current" != "@LICENSE_TOKEN@" ]; then
        ok "license: ${app} already has a token, leaving untouched"
        return 0
    fi

    # Opt-out: if licensing infra isn't deployed yet, skip the whole
    # flow (no pubkey fetch, no prompt, no trial call). vibe.conf's
    # `license_required` defaults to 0 until the licensing server is
    # live; VIBE_LICENSE_REQUIRE=1 in the env force-enables for one
    # invocation. The app's env file still gets DISABLE_LICENSE_CHECK=1
    # so the app itself doesn't enforce.
    local required="${VIBE_LICENSE_REQUIRE:-}"
    if [ -z "$required" ]; then
        required="$(config_get license_required 2>/dev/null)"
    fi
    if [ -z "$required" ] || [ "$required" = "0" ]; then
        secrets_set "$app" DISABLE_LICENSE_CHECK 1
        ok "license: ${app} skipped (license_required=0 in vibe.conf)"
        return 0
    fi

    license_fetch_pubkey "$app" || warn "license: continuing without verified pubkey"

    # 1. Env var (unattended).
    local var token=""
    var="VIBE_LICENSE_TOKEN_$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')"
    if [ -n "${!var:-}" ]; then
        token="${!var}"
        log "license: using token from $var"
    fi

    # 2. Interactive prompt (TTY only).
    if [ -z "$token" ] && [ -t 0 ] && [ "${VIBE_ASSUME_YES:-0}" != "1" ]; then
        echo
        echo "  Enter the license token for ${app} (paste; leave blank for a"
        echo "  30-day trial). Get tokens from https://licensing.kisaes.com."
        read -rp "  Token: " token || token=""
        echo
    fi

    # 3. Trial fallback.
    if [ -z "$token" ]; then
        if token="$(license_request_trial "$app")"; then
            warn "license: trial token issued for ${app} (30-day; upgrade later via 'vibe license set ${app} <token>')"
        else
            warn "license: no token, no trial — leaving DISABLE_LICENSE_CHECK=1"
            secrets_set "$app" DISABLE_LICENSE_CHECK 1
            return 0
        fi
    fi

    secrets_set "$app" LICENSE_TOKEN "$token"
    secrets_set "$app" DISABLE_LICENSE_CHECK 0
    ok "license: activated ${app}"
}

# ---------- `vibe license set <app> <token>` ----------
license_set() {
    local app="$1" token="$2"
    require_root
    [ -n "$app" ]   || die "usage: vibe license set <app> <token>"
    [ -n "$token" ] || die "usage: vibe license set <app> <token>"
    license_fetch_pubkey "$app" || warn "license: continuing without verified pubkey"
    secrets_set "$app" LICENSE_TOKEN "$token"
    secrets_set "$app" DISABLE_LICENSE_CHECK 0
    ok "license: token replaced for ${app} — restart with 'vibe upgrade ${app}' to pick it up"
}
