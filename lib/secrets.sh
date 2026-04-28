#!/usr/bin/env bash
# Per-app secret generation + persistence.
#
# Secrets are written to /etc/vibe/<app>/.env (mode 0600, owned by `vibe`).
# Existing values are NEVER overwritten — re-running `vibe install` is safe.
# Rotation lives in PR (v1.1) `vibe rotate-secrets <app>`.
#
# common.sh is sourced by callers; we use die/log/ok/warn from there.

# ---------- Generators ----------

# 64 hex chars (32 bytes) — for ENCRYPTION_KEY-style aes-gcm keys.
secrets_hex32() {
    openssl rand -hex 32
}

# 48-byte url-safe base64 — for JWT_SECRET, SESSION_SECRET-style HMAC keys.
secrets_b64_48() {
    openssl rand -base64 48 | tr -d '\n=' | tr '/+' '_-'
}

# 32-byte base64 with /+= stripped — matches the docker-compose hint
# `openssl rand -base64 32 | tr -d '/+='`. Used for POSTGRES_PASSWORD.
secrets_db_password() {
    openssl rand -base64 32 | tr -d '/+='
}

# 2048-bit RSA keypair. Outputs the PEM private key on stdout; caller writes
# it to disk and derives the pubkey via `openssl pkey -pubout`.
secrets_rsa_private_pem() {
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null
}

secrets_rsa_pubkey_from_priv() {
    local priv="$1"
    openssl pkey -in "$priv" -pubout 2>/dev/null
}

# ---------- Per-app env file management ----------

# Path to the env file for an app.
secrets_env_path() {
    local app="$1"
    printf '%s\n' "${VIBE_ETC}/${app}/.env"
}

# Ensure the app's env directory exists with correct ownership/perms.
secrets_ensure_envdir() {
    local app="$1"
    local dir="${VIBE_ETC}/${app}"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$dir"
}

# Read a key from the app's env file. Empty string if absent.
secrets_get() {
    local app="$1" key="$2"
    local f
    f="$(secrets_env_path "$app")"
    [ -f "$f" ] || { printf ''; return 0; }
    awk -F= -v k="$key" '
        /^[[:space:]]*#/ { next }
        $1 == k { sub(/^[^=]*=/,""); print; exit }
    ' "$f"
}

# Set a key in the app's env file. Creates the file if missing. 0600.
# Atomic via mktemp+mv.
secrets_set() {
    local app="$1" key="$2" value="$3"
    require_root
    secrets_ensure_envdir "$app"
    local f
    f="$(secrets_env_path "$app")"

    # Don't echo `set -x` over the value
    set +x

    if [ ! -f "$f" ]; then
        : > "$f"
        chown "$VIBE_USER:$VIBE_USER" "$f"
        chmod 0600 "$f"
    fi

    local tmp
    tmp="$(mktemp "${f}.XXXXXX")"
    chown "$VIBE_USER:$VIBE_USER" "$tmp"
    chmod 0600 "$tmp"
    if grep -q "^${key}=" "$f" 2>/dev/null; then
        awk -F= -v k="$key" -v v="$value" '
            BEGIN { OFS="=" }
            /^[[:space:]]*#/ { print; next }
            $1 == k { print k "=" v; next }
            { print }
        ' "$f" > "$tmp"
    else
        cp "$f" "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" "$f"
    chown "$VIBE_USER:$VIBE_USER" "$f"
    chmod 0600 "$f"
}

# Set a key only if not already present (or set to empty / placeholder).
# Returns 0 in either case; emits a log line on actual writes.
secrets_set_if_unset() {
    local app="$1" key="$2" value="$3"
    local current
    current="$(secrets_get "$app" "$key")"
    case "$current" in
        ""|@*@) secrets_set "$app" "$key" "$value"; dbg "secret: ${app}.${key} generated" ;;
        *)      dbg "secret: ${app}.${key} already set, leaving" ;;
    esac
}

# Render an app's env.template to /etc/vibe/<app>/.env, expanding @PLACEHOLDER@
# tokens via env vars set by the caller. Existing file is NOT overwritten —
# this is for first-install only; subsequent edits go through secrets_set.
secrets_render_env_template() {
    local app="$1"
    require_root
    secrets_ensure_envdir "$app"
    local tpl="${VIBE_PREFIX}/apps/${app}/env.template"
    local out
    out="$(secrets_env_path "$app")"
    [ -f "$tpl" ] || die "env template missing: $tpl"
    if [ -f "$out" ]; then
        warn "env file already exists at $out — not overwriting"
        return 0
    fi

    # Generate fresh secrets and export so envsubst-style sed picks them up.
    local pg jwt enc plaid
    pg="$(secrets_db_password)"
    jwt="$(secrets_b64_48)"
    enc="$(secrets_hex32)"
    plaid="$(secrets_hex32)"

    # Allow overrides for the non-secret placeholders.
    : "${VIBE_MYBOOKS_VERSION:=1.4}"
    : "${DISABLE_LICENSE_CHECK:=1}"   # license.sh flips to 0 once a token lands
    : "${LICENSE_TOKEN:=}"

    # Substitute placeholders. Use `|` as sed delimiter so URL-safe values pass
    # through cleanly.
    sed \
        -e "s|@POSTGRES_PASSWORD@|${pg}|g" \
        -e "s|@JWT_SECRET@|${jwt}|g" \
        -e "s|@ENCRYPTION_KEY@|${enc}|g" \
        -e "s|@PLAID_ENCRYPTION_KEY@|${plaid}|g" \
        -e "s|@VIBE_MYBOOKS_VERSION@|${VIBE_MYBOOKS_VERSION}|g" \
        -e "s|@DISABLE_LICENSE_CHECK@|${DISABLE_LICENSE_CHECK}|g" \
        -e "s|@LICENSE_TOKEN@|${LICENSE_TOKEN}|g" \
        "$tpl" > "$out"

    chown "$VIBE_USER:$VIBE_USER" "$out"
    chmod 0600 "$out"
    ok "rendered $out (mode 0600)"
}

# Sanity check: refuse to start an app with placeholder values still present.
# Catches BOTH whole-line `KEY=@PLACEHOLDER@` AND placeholders embedded in
# composite values (e.g. `DATABASE_URL=postgres://user:@PG_PASSWORD@@host/db`
# where a missed substitution leaves @PG_PASSWORD@ inside the URL). Allows
# `@` in legitimate places (email defaults like `noreply@example.com`,
# Caddy global directives) by anchoring on `@WORD@` with at least one
# uppercase letter or digit between the `@` markers.
secrets_assert_no_placeholders() {
    local app="$1"
    local f
    f="$(secrets_env_path "$app")"
    [ -f "$f" ] || die "env file missing: $f"
    if grep -qE '@[A-Z][A-Z0-9_]*@' "$f"; then
        err "$f still contains @PLACEHOLDER@ tokens — secret generation failed"
        grep -nE '@[A-Z][A-Z0-9_]*@' "$f" >&2 || true
        return 1
    fi
}

# ---------- File-based secrets (Docker secrets pattern) ----------
# Some apps (Connect, TB, Payroll) use POSTGRES_PASSWORD_FILE so the password
# never appears in `docker inspect` output. This writes a single-value file
# with no trailing newline (Postgres rejects passwords with a trailing \n).
secrets_write_file() {
    local app="$1" name="$2" value="$3"
    require_root
    secrets_ensure_envdir "$app"
    local path="${VIBE_ETC}/${app}/${name}"
    if [ -f "$path" ] && [ -s "$path" ]; then
        dbg "secret file ${path} already exists, leaving"
        return 0
    fi
    set +x
    printf '%s' "$value" > "$path"
    chown "$VIBE_USER:$VIBE_USER" "$path"
    chmod 0600 "$path"
    ok "wrote secret file ${path} (mode 0600)"
}

# Read a previously written secret file.
secrets_read_file() {
    local app="$1" name="$2"
    local path="${VIBE_ETC}/${app}/${name}"
    [ -f "$path" ] || return 1
    cat "$path"
}
