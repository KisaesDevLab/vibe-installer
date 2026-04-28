#!/usr/bin/env bash
# /etc/vibe/vibe.conf read/write + snapshot/restore for transactional ops.
#
# vibe.conf format: shell-sourceable KEY=VALUE lines.
#   mode=single|multi             (legacy 'single' migrated to 'multi' on
#                                  next vibe invocation; new installs are
#                                  always multi)
#   host=vibe.local
#   tls_mode=internal|acme|cf-tunnel
#   acme_email=<contact email>    (only used when tls_mode=acme)
#   installed=mybooks,connect     (comma-separated, sorted)
#   license_pubkey_fetched_at=<unix-ts>

# common.sh defines VIBE_CONF, VIBE_ETC, log/ok/warn/err.

config_init() {
    if [ -f "$VIBE_CONF" ]; then return 0; fi
    require_root
    install -d -m 0755 "$VIBE_ETC"
    cat > "$VIBE_CONF" <<'EOF'
# vibe-installer config — managed by `vibe`. Hand-edit at your own risk.
mode=multi
host=vibe.local
tls_mode=internal
acme_email=
installed=
license_pubkey_fetched_at=0
EOF
    chmod 0644 "$VIBE_CONF"
}

# Read a single key. Empty string if unset / file missing.
config_get() {
    local key="$1"
    [ -f "$VIBE_CONF" ] || { printf ''; return 0; }
    awk -F= -v k="$key" '
        /^[[:space:]]*#/ { next }
        $1 == k { sub(/^[^=]*=/,""); print; exit }
    ' "$VIBE_CONF"
}

# Set or update a key. Atomic via mktemp+mv.
config_set() {
    local key="$1" value="$2"
    require_root
    config_init
    local tmp
    tmp="$(mktemp "${VIBE_CONF}.XXXXXX")"
    if grep -q "^${key}=" "$VIBE_CONF"; then
        awk -F= -v k="$key" -v v="$value" '
            /^[[:space:]]*#/ { print; next }
            $1 == k { print k "=" v; next }
            { print }
        ' "$VIBE_CONF" > "$tmp"
    else
        cp "$VIBE_CONF" "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    chmod 0644 "$tmp"
    mv "$tmp" "$VIBE_CONF"
}

# Comma-separated list helpers for `installed`
config_installed_list() {
    local raw
    raw="$(config_get installed)"
    [ -z "$raw" ] && return 0
    printf '%s\n' "$raw" | tr ',' '\n' | sed '/^$/d' | sort -u
}

config_installed_count() {
    config_installed_list | wc -l | tr -d ' '
}

config_installed_has() {
    local app="$1"
    config_installed_list | grep -qx "$app"
}

config_installed_add() {
    local app="$1"
    local current new
    current="$(config_get installed)"
    if config_installed_has "$app"; then return 0; fi
    if [ -z "$current" ]; then
        new="$app"
    else
        new="$(printf '%s\n%s' "$current" "$app" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -)"
    fi
    config_set installed "$new"
}

config_installed_remove() {
    local app="$1"
    local new
    # `grep -vx` returns 1 when every line matches (i.e. nothing left after
    # the filter) — under `set -o pipefail` that propagates and crashes the
    # caller. Wrap in `|| true` so removing the last app yields an empty
    # `installed=` line cleanly.
    new="$(config_installed_list | { grep -vx "$app" || true; } | paste -sd, -)"
    config_set installed "$new"
}

# ---------- Snapshot / restore (transactional rollback) ----------
config_snapshot() {
    [ -f "$VIBE_CONF" ] || return 0
    cp -p "$VIBE_CONF" "${VIBE_CONF}.bak"
    dbg "snapshot: ${VIBE_CONF}.bak"
}

config_restore() {
    if [ -f "${VIBE_CONF}.bak" ]; then
        mv "${VIBE_CONF}.bak" "$VIBE_CONF"
        warn "restored ${VIBE_CONF} from snapshot"
    fi
}

config_commit() {
    rm -f "${VIBE_CONF}.bak"
}

# Pretty-print all config (used by `vibe status`)
config_dump() {
    [ -f "$VIBE_CONF" ] || { warn "no config at $VIBE_CONF — run install.sh first"; return 1; }
    awk '/^[[:space:]]*#/ || NF==0 { next } { print }' "$VIBE_CONF"
}
