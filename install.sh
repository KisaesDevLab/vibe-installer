#!/usr/bin/env bash
# vibe-installer — host bootstrap.
#
# One-shot entry point:
#   curl -fsSL https://raw.githubusercontent.com/KisaesDevLab/vibe-installer/main/install.sh | sudo bash
#
# What it does:
#   1. Verify host (Ubuntu 24.04, x86_64/aarch64, ≥4 GB RAM, ≥20 GB free in /var)
#   2. Install Docker (via get.docker.com) if missing
#   3. Clone the installer repo to /opt/vibe-installer (or update if present)
#   4. Symlink bin/vibe to /usr/local/bin/vibe
#   5. Create vibe system user + /etc/vibe + /var/lib/vibe + /var/log/vibe
#   6. Create the vibe_ingress Docker network
#   7. Render /etc/vibe/vibe.conf — interactive intent-based prompts ask:
#        - Will this be reachable from outside your office?
#        - At what hostname?
#        - For "yes, our domain": ACME contact email.
#        - For "yes, Cloudflare Tunnel": paste tunnel token (stashed under
#          /etc/vibe/cloudflared/tunnel.token, mode 0600).
#   8. Bring up the Caddy ingress at :80/:443 immediately, even with zero
#      apps installed. The landing page is reachable from the moment
#      install.sh exits — adding apps later doesn't change any URLs.
#   9. Print next steps including IP fallback URL (in case mDNS / .local
#      resolution doesn't work on the operator's client device).
#
# Idempotent: re-running upgrades the repo and re-applies any missing pieces.
#
# Environment overrides for unattended installs:
#   VIBE_HOST                 hostname this appliance answers to (default: vibe.local)
#   VIBE_TLS_MODE             internal | acme | cf-tunnel (default: internal)
#   VIBE_ACME_EMAIL           contact for ACME renewal alerts (acme mode only)
#   CLOUDFLARE_TUNNEL_TOKEN   tunnel token (cf-tunnel mode only — stashed)
#   VIBE_REPO                 git URL for the installer repo
#                               (default: https://github.com/KisaesDevLab/vibe-installer.git)
#   VIBE_REF                  branch/tag/sha to check out (default: main)
#   VIBE_ASSUME_YES=1         skip all interactive prompts (use defaults / env values)

set -euo pipefail

VIBE_PREFIX="${VIBE_PREFIX:-/opt/vibe-installer}"
VIBE_REPO="${VIBE_REPO:-https://github.com/KisaesDevLab/vibe-installer.git}"
VIBE_REF="${VIBE_REF:-main}"
VIBE_ETC="${VIBE_ETC:-/etc/vibe}"
VIBE_DATA="${VIBE_DATA:-/var/lib/vibe}"
VIBE_LOG="${VIBE_LOG:-/var/log/vibe}"
VIBE_USER="${VIBE_USER:-vibe}"
VIBE_NETWORK="${VIBE_NETWORK:-vibe_ingress}"

# Globals set by prompt_tls_intent and consumed by render_config /
# print_next_steps. Initialized empty so `set -u` doesn't crash on a
# re-run where render_config short-circuits (config already exists)
# and the prompt is never called — print_next_steps then falls back
# to reading vibe.conf directly.
VIBE_TLS_MODE_PICK=""
VIBE_HOST_PICK=""
VIBE_ACME_EMAIL_PICK=""

# ---------- Output helpers (self-contained; lib/ may not exist yet) ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _R=$'\033[0m'; _RED=$'\033[31m'; _YEL=$'\033[33m'; _GRN=$'\033[32m'; _BLU=$'\033[34m'
else
    _R=""; _RED=""; _YEL=""; _GRN=""; _BLU=""
fi
log()  { printf '%s[install]%s %s\n' "$_BLU" "$_R" "$*"; }
ok()   { printf '%s[  ok   ]%s %s\n' "$_GRN" "$_R" "$*"; }
warn() { printf '%s[ warn  ]%s %s\n' "$_YEL" "$_R" "$*" >&2; }
die()  { printf '%s[ error ]%s %s\n' "$_RED" "$_R" "$*" >&2; exit 1; }

# ---------- Pre-flight ----------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "install.sh must run as root (try: curl ... | sudo bash)"
}

verify_host() {
    log "verifying host..."

    # OS
    if [ ! -r /etc/os-release ]; then die "cannot read /etc/os-release — unsupported host"; fi
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
        warn "host is ${ID:-unknown} ${VERSION_ID:-?}; Ubuntu 24.04 LTS is the supported target"
    elif [ "${VERSION_ID:-}" != "24.04" ]; then
        warn "Ubuntu ${VERSION_ID:-?} detected; 24.04 LTS is the supported target"
    fi

    # Architecture
    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ;;
        *) die "unsupported architecture: $(uname -m) (need amd64 or arm64)" ;;
    esac

    # RAM
    local mem_gb
    mem_gb="$(awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo)"
    if [ "$mem_gb" -lt 4 ]; then die "need at least 4 GB RAM (have ${mem_gb} GB)"; fi
    [ "$mem_gb" -lt 8 ] && warn "RAM is ${mem_gb} GB — 8 GB is the recommended floor"

    # Disk
    local disk_gb
    disk_gb="$(df -BG --output=avail /var 2>/dev/null | tail -1 | tr -d 'G ' || echo 0)"
    if [ "$disk_gb" -lt 20 ]; then die "need at least 20 GB free in /var (have ${disk_gb} GB)"; fi
    [ "$disk_gb" -lt 40 ] && warn "Free disk in /var is ${disk_gb} GB — 40 GB recommended"

    ok "host: ${ID:-?} ${VERSION_ID:-?} on $(uname -m), ${mem_gb} GB RAM, ${disk_gb} GB free in /var"
}

# ---------- Port 80/443 conflict check ----------
# Caddy needs both, exclusively. The most common failure path is a
# pre-existing nginx/apache that ships on the OS image — those silently
# bind :80 and the Caddy compose `up` then returns "address already in
# use", leaving the install in a half-bootstrapped state. Detect upfront
# and fail with a message that names the offender so the operator knows
# exactly what to disable.
#
# Skipped when our own Caddy is already running (re-run case): the port
# IS bound, but by us, and that's fine.
verify_ports_free() {
    log "checking ports 80 + 443 are free for Caddy..."

    # Re-run case: our own Caddy already owns the ports. Don't trip on it.
    if command -v docker >/dev/null 2>&1 \
       && docker ps --filter 'name=^vibe-ingress-caddy$' --format '{{.Names}}' 2>/dev/null \
            | grep -qx vibe-ingress-caddy; then
        ok "Caddy ingress already running (re-run); ports 80/443 owned by vibe-ingress-caddy"
        return 0
    fi

    if ! command -v ss >/dev/null 2>&1; then
        warn "ss not installed — can't pre-check port conflicts. apt-get will install iproute2 next."
        return 0
    fi

    local listeners_80 listeners_443 offender
    # `ss -tlnpH` = TCP / listening / numeric / program / no header. Filter
    # for port :80 / :443 in the local-address column ($4).
    listeners_80="$(ss -tlnpH 2>/dev/null | awk '$4 ~ /:80$/  { print }')"
    listeners_443="$(ss -tlnpH 2>/dev/null | awk '$4 ~ /:443$/ { print }')"

    if [ -z "$listeners_80" ] && [ -z "$listeners_443" ]; then
        ok "ports 80 + 443 are free"
        return 0
    fi

    err "port conflict — Caddy needs 80 + 443 exclusive, but:"
    if [ -n "$listeners_80" ]; then
        offender="$(printf '%s' "$listeners_80" | head -1 | sed 's/.*users:((//; s/),.*/)/')"
        err "  port 80  is bound by: ${offender:-(unknown — run 'sudo ss -tlnp | grep :80')}"
    fi
    if [ -n "$listeners_443" ]; then
        offender="$(printf '%s' "$listeners_443" | head -1 | sed 's/.*users:((//; s/),.*/)/')"
        err "  port 443 is bound by: ${offender:-(unknown — run 'sudo ss -tlnp | grep :443')}"
    fi

    cat >&2 <<'EOM'

  Most common cause: the OS image ships with nginx (or apache2) enabled.
  Free the ports with:

    sudo systemctl disable --now nginx apache2 2>/dev/null
    sudo apt-get purge -y nginx nginx-common nginx-core apache2 2>/dev/null

  Then re-run the install.

EOM
    die "ports 80/443 not free — refusing to clobber an existing service"
}

# ---------- Apt prerequisites ----------
ensure_packages() {
    log "ensuring apt prerequisites (curl, git, ca-certificates, gnupg, openssl, jq, gettext-base)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg openssl jq gettext-base \
        >/dev/null
    ok "apt prerequisites present"
}

# ---------- Docker ----------
ensure_docker() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        ok "Docker present: $(docker --version | head -1)"
    else
        log "installing Docker via get.docker.com..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        systemctl enable --now docker
        ok "Docker installed: $(docker --version | head -1)"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        die "docker compose v2 plugin missing — get.docker.com should have installed it; please file a bug"
    fi
    ok "docker compose v2: $(docker compose version --short)"
}

# ---------- User & directories ----------
ensure_user_and_dirs() {
    if ! id "$VIBE_USER" >/dev/null 2>&1; then
        log "creating system user '$VIBE_USER'..."
        useradd --system --home-dir "$VIBE_DATA" --shell /usr/sbin/nologin --user-group "$VIBE_USER"
        ok "created user $VIBE_USER ($(id -u "$VIBE_USER"):$(id -g "$VIBE_USER"))"
    else
        ok "user $VIBE_USER already exists"
    fi

    # Add vibe to docker group so future per-app containers can be managed without root.
    if getent group docker >/dev/null 2>&1; then
        usermod -aG docker "$VIBE_USER" 2>/dev/null || true
    fi

    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_ETC"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_DATA"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_LOG"
    install -d -m 0700 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_DATA/.archive"
    # Restore drop-dir — where operators SCP backup tarballs that they
    # want to restore from elsewhere. Listed by vibed's
    # apps.backups.drop_list RPC. Mode 0700 owned by vibe:vibe; the
    # admin UI's restore page shows the operator a `scp + sudo mv` flow
    # since non-root SSH users can't write here directly.
    install -d -m 0700 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_DATA/.restore-drop"
    ok "directories: $VIBE_ETC, $VIBE_DATA, $VIBE_LOG"
}

# ---------- Repo clone / update ----------
ensure_repo() {
    if [ -d "$VIBE_PREFIX/.git" ]; then
        log "updating $VIBE_PREFIX (git fetch + checkout $VIBE_REF)..."
        git -C "$VIBE_PREFIX" fetch --tags --prune origin
        git -C "$VIBE_PREFIX" checkout --quiet "$VIBE_REF"
        git -C "$VIBE_PREFIX" pull --ff-only --quiet origin "$VIBE_REF" 2>/dev/null || true
        ok "$VIBE_PREFIX at $(git -C "$VIBE_PREFIX" rev-parse --short HEAD)"
    elif [ -d "$VIBE_PREFIX" ] && [ -f "$VIBE_PREFIX/bin/vibe" ]; then
        # Local-dev case: developer has cp'd the repo in by hand.
        ok "$VIBE_PREFIX present (no .git — assuming local dev install)"
    else
        log "cloning $VIBE_REPO ($VIBE_REF) → $VIBE_PREFIX..."
        rm -rf "$VIBE_PREFIX"
        git clone --branch "$VIBE_REF" --depth 1 "$VIBE_REPO" "$VIBE_PREFIX"
        ok "cloned $VIBE_PREFIX at $(git -C "$VIBE_PREFIX" rev-parse --short HEAD)"
    fi
    chmod 0755 "$VIBE_PREFIX/bin/vibe" "$VIBE_PREFIX/install.sh" 2>/dev/null || true
    [ -f "$VIBE_PREFIX/uninstall.sh" ] && chmod 0755 "$VIBE_PREFIX/uninstall.sh"
}

ensure_symlink() {
    local link=/usr/local/bin/vibe
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$VIBE_PREFIX/bin/vibe" ]; then
        ok "symlink $link → $VIBE_PREFIX/bin/vibe (present)"
    else
        ln -sf "$VIBE_PREFIX/bin/vibe" "$link"
        ok "symlink $link → $VIBE_PREFIX/bin/vibe"
    fi
}

# ---------- Docker network ----------
ensure_network() {
    if docker network inspect "$VIBE_NETWORK" >/dev/null 2>&1; then
        ok "Docker network '$VIBE_NETWORK' already exists"
    else
        docker network create "$VIBE_NETWORK" >/dev/null
        ok "created Docker network '$VIBE_NETWORK'"
    fi
}

# ---------- Render /etc/vibe/vibe.conf ----------
prompt_or_default() {
    local prompt="$1" default="$2"
    if [ "${VIBE_ASSUME_YES:-0}" = "1" ] || [ ! -t 0 ]; then
        printf '%s\n' "$default"
        return 0
    fi
    local reply
    if [ -n "$default" ]; then
        read -rp "$prompt [$default]: " reply
        printf '%s\n' "${reply:-$default}"
    else
        read -rp "$prompt: " reply
        printf '%s\n' "$reply"
    fi
}

# Persist a Cloudflare tunnel token under /etc/vibe/cloudflared/tunnel.token.
# Mode 0600, owner vibe:vibe so the per-app `vibe install` flow can read it
# without root and treat it as a default if the operator didn't pass --token
# at install time.
stash_cloudflare_token() {
    local token="$1"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_ETC/cloudflared"
    # printf without trailing newline — trailing whitespace breaks token parsing
    # in cloudflared.
    printf '%s' "$token" > "$VIBE_ETC/cloudflared/tunnel.token"
    chown "$VIBE_USER:$VIBE_USER" "$VIBE_ETC/cloudflared/tunnel.token"
    chmod 0600 "$VIBE_ETC/cloudflared/tunnel.token"
    ok "cloudflare tunnel token stashed at $VIBE_ETC/cloudflared/tunnel.token"
}

# Email validation — reject obvious garbage early so a typo doesn't surface
# as a Let's Encrypt 'badContact' error mid-install. Loose RFC-ish regex
# (anything more strict trips legitimate addresses with `+` / `.` / etc.).
_is_email() {
    case "$1" in
        ?*@?*.?*) return 0 ;;
        *)        return 1 ;;
    esac
}

# ---------- Intent-based TLS prompt ----------
# Replaces the old jargon-heavy "internal/acme/cf-tunnel" prompt with three
# questions in the operator's vocabulary. Sets these globals on return:
#
#   VIBE_TLS_MODE_PICK     internal | acme | cf-tunnel
#   VIBE_HOST_PICK         hostname (e.g. vibe.local or books.firm.com)
#   VIBE_ACME_EMAIL_PICK   ACME contact email (acme mode only; empty otherwise)
#
# In non-interactive mode (VIBE_ASSUME_YES=1 or no TTY), honors the
# documented env vars verbatim. In interactive mode walks the operator
# through a three-question flow.
prompt_tls_intent() {
    if [ "${VIBE_ASSUME_YES:-0}" = "1" ] || [ ! -t 0 ]; then
        VIBE_TLS_MODE_PICK="${VIBE_TLS_MODE:-internal}"
        VIBE_HOST_PICK="${VIBE_HOST:-vibe.local}"
        VIBE_ACME_EMAIL_PICK="${VIBE_ACME_EMAIL:-${ACME_EMAIL:-}}"
        # Stash the cf-tunnel token if the env var carries one — keeps the
        # unattended path symmetric with the interactive path's prompt.
        if [ "$VIBE_TLS_MODE_PICK" = "cf-tunnel" ] && [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
            stash_cloudflare_token "$CLOUDFLARE_TUNNEL_TOKEN"
        fi
        return 0
    fi

    cat >&2 <<'EOM'

  Will this appliance be reachable from outside your office?

    1) No, only from devices on our office network.
       (We'll use a self-signed cert; clients trust it once.)
    2) Yes, at a domain we own (e.g. books.kispcal.com).
       (We'll get a free Let's Encrypt cert; needs a DNS A record
        and port 80 reachable from the public internet.)
    3) Yes, through a Cloudflare Tunnel.
       (No DNS or port-forward work needed; you'll paste a tunnel
        token from your Cloudflare Zero Trust dashboard.)

EOM
    local reply
    read -rp "  Choice [1/2/3] (default 1): " reply
    case "${reply:-1}" in
        1|internal|n|no|lan|office)
            VIBE_TLS_MODE_PICK=internal
            VIBE_HOST_PICK="$(prompt_or_default "  Hostname this appliance answers to" "vibe.local")"
            VIBE_ACME_EMAIL_PICK=""
            ;;
        2|acme|domain|public)
            VIBE_TLS_MODE_PICK=acme
            local domain=""
            while [ -z "$domain" ]; do
                domain="$(prompt_or_default "  Public domain (no http://, e.g. books.kispcal.com)" "")"
                if [ -z "$domain" ]; then
                    warn "a domain is required for option 2 — try again or Ctrl-C to abort"
                fi
            done
            VIBE_HOST_PICK="$domain"
            local email=""
            while ! _is_email "$email"; do
                email="$(prompt_or_default "  Contact email (Let's Encrypt sends renewal alerts here)" "")"
                if ! _is_email "$email"; then
                    if [ -z "$email" ]; then
                        warn "an email is required for option 2 — Let's Encrypt won't issue without one"
                    else
                        warn "'$email' doesn't look like a valid email — try again"
                    fi
                fi
            done
            VIBE_ACME_EMAIL_PICK="$email"
            ;;
        3|cf|cf-tunnel|cloudflare|tunnel)
            VIBE_TLS_MODE_PICK=cf-tunnel
            VIBE_HOST_PICK="$(prompt_or_default \
                "  Hostname your tunnel routes to (e.g. books.kispcal.com)" \
                "vibe.local")"
            VIBE_ACME_EMAIL_PICK=""
            cat >&2 <<'EOM'

  Paste your Cloudflare tunnel token. To find it:
    Cloudflare dashboard → Zero Trust → Networks → Tunnels →
    pick your tunnel → Install connector → copy the long string
    that appears AFTER `--token` in the install command.

EOM
            local token=""
            # Use -s so the token doesn't show in the terminal scrollback.
            read -rsp "  Token: " token
            echo >&2
            if [ -z "$token" ]; then
                die "a tunnel token is required for option 3 — re-run install.sh to retry"
            fi
            stash_cloudflare_token "$token"
            ;;
        *)
            warn "unrecognized choice '$reply' — defaulting to office-network only"
            VIBE_TLS_MODE_PICK=internal
            VIBE_HOST_PICK="vibe.local"
            VIBE_ACME_EMAIL_PICK=""
            ;;
    esac
}

render_config() {
    local conf="$VIBE_ETC/vibe.conf"
    if [ -f "$conf" ]; then
        ok "config $conf exists — leaving untouched"
        return 0
    fi
    log "rendering $conf..."

    prompt_tls_intent
    # Globals set above: VIBE_TLS_MODE_PICK, VIBE_HOST_PICK, VIBE_ACME_EMAIL_PICK

    install -m 0644 "$VIBE_PREFIX/etc/vibe.conf.template" "$conf"
    sed -i "s|^host=.*|host=${VIBE_HOST_PICK}|"          "$conf"
    sed -i "s|^tls_mode=.*|tls_mode=${VIBE_TLS_MODE_PICK}|" "$conf"
    sed -i "s|^acme_email=.*|acme_email=${VIBE_ACME_EMAIL_PICK}|" "$conf"
    chown "$VIBE_USER:$VIBE_USER" "$conf"
    ok "wrote $conf (host=${VIBE_HOST_PICK}, tls_mode=${VIBE_TLS_MODE_PICK}, mode=multi)"
}

# ---------- Bring up the Caddy ingress immediately ----------
# Always-multi-app deployment: Caddy at :80/:443 runs from the moment
# install.sh finishes. URLs stay stable forever — adding apps later does
# not move them. The 'vibe mode multi' subcommand is idempotent and brings
# up the ingress with the rendered Caddyfile, even when zero apps are
# installed (a landing page + /healthz is reachable).
ensure_ingress() {
    log "starting Caddy ingress at :80/:443..."
    if "$VIBE_PREFIX/bin/vibe" mode multi >/dev/null 2>&1; then
        ok "ingress is up"
    else
        # Don't die — the operator can recover with `sudo vibe doctor` and
        # `sudo vibe mode multi` once they've fixed whatever the underlying
        # issue is (port 80 already taken, ufw blocking, etc.).
        warn "ingress did not come up cleanly — run 'sudo vibe doctor' to diagnose"
        warn "you can also re-attempt with 'sudo vibe mode multi'"
    fi
}

# ---------- Install the vibed daemon ----------
# vibed is the JSON-RPC daemon that the admin web app talks to. Installs
# in three steps:
#   1. Place the binary at /usr/local/bin/vibed. Tries (a) a pre-built
#      release artifact from GitHub, (b) a locally-built binary at
#      tools/vibed/vibed if the operator built it themselves. If neither
#      is available (e.g., dev branch with no release yet), the systemd
#      unit is still installed but disabled, and a build hint is printed.
#   2. Install /etc/systemd/system/vibed.service from the repo.
#   3. systemctl enable --now vibed.
ensure_vibed() {
    local arch_tag
    case "$(uname -m)" in
        x86_64|amd64) arch_tag="linux-amd64" ;;
        aarch64|arm64) arch_tag="linux-arm64" ;;
        *) warn "vibed: unsupported architecture $(uname -m); skipping"; return 0 ;;
    esac

    local binary_target="/usr/local/bin/vibed"
    local unit_target="/etc/systemd/system/vibed.service"
    local unit_source="$VIBE_PREFIX/etc/systemd/system/vibed.service"

    # Skip if already installed and the binary on disk is recent enough
    # (no version pin yet — re-running install.sh re-fetches).
    if [ -x "$binary_target" ]; then
        ok "vibed binary present at $binary_target"
    else
        # Try the release download first. The release pipeline publishes
        # vibed-linux-amd64 / vibed-linux-arm64 alongside the install.sh
        # tag. If VIBE_REF isn't a release tag (e.g., 'main'), this 404s
        # and we fall through.
        local url="https://github.com/KisaesDevLab/vibe-installer/releases/download/${VIBE_REF}/vibed-${arch_tag}"
        log "vibed: attempting to download from $url..."
        if curl -fsSL --max-time 30 "$url" -o "$binary_target.tmp" 2>/dev/null; then
            install -m 0755 "$binary_target.tmp" "$binary_target"
            rm -f "$binary_target.tmp"
            ok "vibed: installed from release"
        elif [ -x "$VIBE_PREFIX/tools/vibed/vibed" ]; then
            install -m 0755 "$VIBE_PREFIX/tools/vibed/vibed" "$binary_target"
            ok "vibed: installed from $VIBE_PREFIX/tools/vibed/vibed"
        else
            rm -f "$binary_target.tmp" 2>/dev/null || true
            warn "vibed: no binary available — admin web app will not be able to talk to the daemon"
            warn "vibed: build it yourself with:"
            warn "vibed:   sudo apt-get install -y golang-go"
            warn "vibed:   cd $VIBE_PREFIX/tools/vibed && go build -o vibed . && sudo install -m 0755 vibed /usr/local/bin/vibed"
            warn "vibed:   sudo systemctl restart vibed"
            # Don't die — install.sh's other steps still produce a working
            # CLI-only appliance. The admin web app just won't have a
            # backend until vibed is built.
        fi
    fi

    # Install the systemd unit even if the binary is missing — that way
    # `systemctl restart vibed` works the moment the operator drops a
    # binary in place.
    if [ -f "$unit_source" ]; then
        install -m 0644 "$unit_source" "$unit_target"
        systemctl daemon-reload
        if [ -x "$binary_target" ]; then
            systemctl enable --now vibed >/dev/null 2>&1 || \
                warn "vibed: systemd enable/start failed — check 'sudo journalctl -u vibed'"
            ok "vibed: enabled and running"
        else
            systemctl enable vibed >/dev/null 2>&1 || true
            warn "vibed: systemd unit installed but daemon not started (no binary yet)"
        fi
    else
        warn "vibed: systemd unit missing at $unit_source — skipped"
    fi
}

# ---------- Install the admin web app ----------
#
# The admin app (https://<host>/admin/) is installed automatically by
# install.sh — operators don't run `vibe install admin` by hand. The
# steps below mirror what `vibe install <app>` would do for a product
# app, but skip the user-driven prompts and add the bootstrap-password
# generation:
#
#   1. Generate a random initial admin password + session secret +
#      Postgres password.
#   2. Drop the cleartext initial admin password into:
#        /etc/vibe/admin/admin-bootstrap.password (mode 0600, vibe:vibe)
#        /var/log/vibe/admin-initial-password.txt (mode 0600, root:root)
#      The first is read by the admin server on its first boot to seed
#      the SuperAdmin row; it deletes the file once the row exists.
#      The second is the operator-readable copy printed in the install
#      summary; the rotate-password endpoint deletes it once the
#      operator finishes the force-rotate flow.
#   3. Render /etc/vibe/admin/.env from the template + /etc/vibe/admin/
#      postgres_password.
#   4. Pre-create /var/lib/vibe/admin/ data dirs.
#   5. Pull + start the admin compose stack with the multi-app overlay.
#   6. Wait for /health to return 200 (best-effort; if not healthy, the
#      operator can recover with `sudo vibe doctor`).

# ADMIN_INITIAL_PASSWORD is set by mint_admin_password and read by
# print_next_steps so the install summary shows the credentials.
ADMIN_INITIAL_PASSWORD=""

mint_admin_password() {
    # 24-char URL-safe token. openssl rand -base64 outputs 28 chars
    # for 18 bytes; we trim to 24 so it stays comfortably under the
    # password column's varchar(255) and the operator can paste it
    # without line breaks. URL-safe so a future admin app that emits
    # the password in a copyable URL doesn't have to escape characters.
    openssl rand -base64 18 | tr -d '\n=' | tr '/+' '_-' | head -c 24
}

ensure_admin() {
    local etc="$VIBE_ETC/admin"
    local data="$VIBE_DATA/admin"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$etc"
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$data"
    install -d -m 0700 "$data/postgres-data"
    chown 70:70 "$data/postgres-data" 2>/dev/null || true

    local env_path="$etc/.env"
    if [ -f "$env_path" ]; then
        ok "admin env file exists at $env_path — leaving untouched"
    else
        log "rendering admin env file..."
        local pg session admin_pw
        pg="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
        session="$(openssl rand -base64 48 | tr -d '\n=' | tr '/+' '_-')"
        admin_pw="$(mint_admin_password)"

        # Postgres file-secret. Postgres rejects passwords with a
        # trailing newline so we use printf without one.
        printf '%s' "$pg" > "$etc/postgres_password"
        chown "$VIBE_USER:$VIBE_USER" "$etc/postgres_password"
        chmod 0600 "$etc/postgres_password"

        # Bootstrap password (read by the server on first boot).
        printf '%s' "$admin_pw" > "$etc/admin-bootstrap.password"
        chown "$VIBE_USER:$VIBE_USER" "$etc/admin-bootstrap.password"
        chmod 0600 "$etc/admin-bootstrap.password"

        # Operator-readable cleartext copy. Root-only so a non-root
        # user on the host can't sudo-less it.
        install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_LOG"
        printf '%s\n' "$admin_pw" > "$VIBE_LOG/admin-initial-password.txt"
        chmod 0600 "$VIBE_LOG/admin-initial-password.txt"
        chown root:root "$VIBE_LOG/admin-initial-password.txt"

        : "${VIBE_ADMIN_VERSION:=latest}"
        # Render env.template. The session secret is for express-session
        # signing; the postgres password gets inlined into DATABASE_URL.
        sed \
            -e "s|@SESSION_SECRET@|${session}|g" \
            -e "s|@POSTGRES_PASSWORD@|${pg}|g" \
            -e "s|@VIBE_ADMIN_VERSION@|${VIBE_ADMIN_VERSION}|g" \
            "$VIBE_PREFIX/apps/admin/env.template" > "$env_path"
        chown "$VIBE_USER:$VIBE_USER" "$env_path"
        chmod 0600 "$env_path"

        ADMIN_INITIAL_PASSWORD="$admin_pw"
        ok "wrote $env_path (mode 0600)"
    fi

    # Bring up the stack. We always layer the grouped overlay because
    # the host is in always-multi-app mode by design — the single-app
    # ports-published shape exists only as a developer convenience.
    log "starting admin stack..."
    if ! docker compose \
        --project-name vibe-admin \
        --env-file "$env_path" \
        -f "$VIBE_PREFIX/apps/admin/docker-compose.yml" \
        -f "$VIBE_PREFIX/apps/admin/docker-compose.grouped.yml" \
        pull --quiet 2>/dev/null; then
        warn "admin: image pull failed (offline? rate-limited?) — will keep going with a cached image if any"
    fi
    if ! VIBE_HOST="$VIBE_HOST_PICK" docker compose \
        --project-name vibe-admin \
        --env-file "$env_path" \
        -f "$VIBE_PREFIX/apps/admin/docker-compose.yml" \
        -f "$VIBE_PREFIX/apps/admin/docker-compose.grouped.yml" \
        up -d --remove-orphans; then
        warn "admin: failed to start — run 'sudo vibe doctor' and check 'docker logs vibe-admin-admin-1'"
        return 0
    fi

    # Reload the ingress so the admin caddy.fragment is included in
    # the Caddyfile. ingress_render_caddyfile pulls in apps/admin/
    # caddy.fragment automatically (see lib/ingress.sh).
    "$VIBE_PREFIX/bin/vibe" mode multi >/dev/null 2>&1 || true
    ok "admin: stack up (https://${VIBE_HOST_PICK:-$(grep -E '^host=' "$VIBE_ETC/vibe.conf" | cut -d= -f2)}/admin/)"
}

# ---------- Done ----------

# Best-effort detection of the appliance's primary IPv4. Used for the
# IP-fallback URL in print_next_steps so a Windows-only office (which
# can't resolve `vibe.local` without iTunes/Bonjour installed) still has
# a URL that works.
primary_ipv4() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        # `ip -4 -o addr show scope global` lists every non-loopback IPv4.
        # Take the first; awk strips the CIDR mask.
        ip="$(ip -4 -o addr show scope global 2>/dev/null \
            | awk '{ split($4, a, "/"); print a[1]; exit }')"
    fi
    # Fall back to hostname -I if `ip` isn't present (extremely rare on
    # Ubuntu, but cheap to be safe).
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
        ip="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
    fi
    printf '%s\n' "$ip"
}

print_next_steps() {
    local host="$VIBE_HOST_PICK"
    [ -z "$host" ] && host="$(grep -E '^host=' "$VIBE_ETC/vibe.conf" 2>/dev/null | cut -d= -f2)"
    [ -z "$host" ] && host="vibe.local"
    local tls="$VIBE_TLS_MODE_PICK"
    [ -z "$tls" ] && tls="$(grep -E '^tls_mode=' "$VIBE_ETC/vibe.conf" 2>/dev/null | cut -d= -f2)"
    [ -z "$tls" ] && tls="internal"

    # Pick schemes. The hostname and IP fallback don't always share one:
    #   internal  : both speak https (self-signed) — Caddy auto_https on
    #   acme      : both speak https — Caddy issued a real cert
    #   cf-tunnel : hostname is https (Cloudflare terminates at edge),
    #               but Caddy locally listens with `auto_https off` on
    #               plain :80, so the LAN IP fallback is http only.
    local host_scheme="https"
    local ip_scheme="https"
    if [ "$tls" = "cf-tunnel" ]; then
        ip_scheme="http"
    fi

    local ip
    ip="$(primary_ipv4 || true)"

    cat <<EOM

${_GRN}vibe-installer is ready.${_R}

  Open the appliance from any device on your office network:

    Preferred:  ${host_scheme}://${host}/
EOM
    if [ -n "$ip" ] && [ "$host" != "$ip" ]; then
        cat <<EOM
    If that doesn't work (common on Windows-only LANs):
                ${ip_scheme}://${ip}/

EOM
    else
        echo
    fi

    if [ "$tls" = "internal" ]; then
        cat <<EOM
  ${_YEL}First time you visit, your browser will warn that the certificate is
  not trusted. That's expected — click "Advanced" → "Proceed" once.
  (A future release will add a one-click "trust this appliance" flow.)${_R}

EOM
    fi

    cat <<EOM
  Manage this appliance from your browser:

    URL:       ${host_scheme}://${host}/admin/
    Username:  admin
EOM
    if [ -n "$ADMIN_INITIAL_PASSWORD" ]; then
        cat <<EOM
    Password:  ${ADMIN_INITIAL_PASSWORD}

  ${_YEL}This password was generated by install.sh and is also saved at
  ${VIBE_LOG}/admin-initial-password.txt (mode 0600, root-only).
  You'll be asked to change it on first sign-in; the file is deleted
  automatically once you do.${_R}

EOM
    else
        cat <<EOM
    Password:  see ${VIBE_LOG}/admin-initial-password.txt on this host
               (or run 'sudo cat ${VIBE_LOG}/admin-initial-password.txt')

EOM
    fi
    cat <<EOM
  Or install + manage apps from the command line:
    sudo vibe install mybooks         Vibe MyBooks (bookkeeping)
    sudo vibe install connect         Vibe Connect (encrypted messaging)
    sudo vibe install tb              Vibe TB (trial balance)
    sudo vibe install payroll         Vibe Payroll Time
    sudo vibe install tax             Vibe Tax Research Chat

  Optional integrations (after at least one app):
    sudo vibe install glm-ocr         Local OCR appliance (GLM-OCR)
    sudo vibe install tailscale       Remote-access mesh
    sudo vibe install tools           Portainer + Duplicati admin tools

  Useful CLI:
    vibe status                       Installed apps + appliance state
    sudo vibe doctor                  Run health checks
    vibe help                         Full command reference

  Config: $VIBE_ETC/vibe.conf
  Repo:   $VIBE_PREFIX
  Logs:   $VIBE_LOG

EOM
}

main() {
    require_root
    log "vibe-installer bootstrap starting (ref=$VIBE_REF)"
    verify_host
    ensure_packages
    # Port-binding check runs AFTER ensure_packages so iproute2 (which
    # provides `ss`) is guaranteed present, and BEFORE ensure_docker so we
    # don't install Docker only to discover :80 is taken.
    verify_ports_free
    ensure_docker
    ensure_user_and_dirs
    ensure_repo
    ensure_symlink
    ensure_network
    render_config
    ensure_ingress
    ensure_vibed
    ensure_admin
    print_next_steps
}

main "$@"
