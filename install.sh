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
err()  { printf '%s[ error ]%s %s\n' "$_RED" "$_R" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- Install-time logging ----------
# Tee everything install.sh emits (stdout + stderr) into a persistent log
# at /var/log/vibe/install.log so an operator who hits an issue can send
# us the file (and we can run `vibe report` to bundle it). Without this,
# `curl|bash` output scrolls off the terminal and is gone forever.
#
# The `tee` is set up via exec replacement of stdout/stderr, so every
# subsequent printf / command output is captured. Color codes are
# embedded — that's fine for a UTF-8-safe text editor + the operator
# can `cat -v install.log` if they want to see them rendered.
#
# Done BEFORE require_root so even an early "not running as root" failure
# is captured. Falls back to /tmp if /var/log isn't writable yet.
_setup_install_log() {
    # Pick a log path. Prefer /var/log/vibe/ (canonical). If the parent
    # /var/log exists and we're root (we should be — but be defensive),
    # create /var/log/vibe up-front so the FIRST run's log lands there
    # alongside subsequent runs. Falls back to /tmp/ in pathological
    # cases (read-only /var, missing /var, etc.).
    local logdir="$VIBE_LOG"
    if [ ! -d "$logdir" ] && [ "$(id -u)" -eq 0 ] && [ -d /var/log ]; then
        # Mode 0755 + root-owned for now; ensure_user_and_dirs reconciles
        # ownership later in the same run (chown root → vibe).
        mkdir -p "$logdir" 2>/dev/null && chmod 0755 "$logdir" 2>/dev/null
    fi
    if [ ! -d "$logdir" ] || ! { : >> "$logdir/.write-test" 2>/dev/null && rm "$logdir/.write-test"; }; then
        logdir="/tmp"
    fi
    local logpath="$logdir/install-$(date -u +%Y%m%dT%H%M%SZ).log"

    # `tee -a` opens the file in append mode. process substitution
    # (>(...)) creates an FD that bash redirects stdout/stderr into.
    # The log path is exported so other parts of the installer (and a
    # future `vibe report`) can find this run's log.
    export VIBE_INSTALL_LOG="$logpath"
    exec > >(tee -a "$logpath") 2>&1
    printf '\n========== install.sh start: %s ==========\n' "$(date -Is)"
    printf 'log file: %s\n' "$logpath"
    printf 'invocation: %s\n' "${BASH_SOURCE[0]:-/dev/stdin}"
    printf 'env (selected): VIBE_PREFIX=%s VIBE_REF=%s VIBE_ASSUME_YES=%s VIBE_HOST=%s VIBE_TLS_MODE=%s\n' \
        "$VIBE_PREFIX" "$VIBE_REF" "${VIBE_ASSUME_YES:-0}" "${VIBE_HOST:-<unset>}" "${VIBE_TLS_MODE:-<unset>}"
    printf '==========================================================\n\n'
}
_setup_install_log

# Final newline + footer at exit so `vibe report` knows the run boundary.
_install_log_footer() {
    local rc=$?
    printf '\n========== install.sh exit: %s rc=%d ==========\n' "$(date -Is)" "$rc"
}
trap _install_log_footer EXIT

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

    # Top-level dirs are 0755 (world-traversable) so non-root operators
    # can run read-only commands like `vibe status`, `vibe doctor`, and
    # `vibe upgrade-check`. Secrets aren't exposed by this — every per-app
    # subdirectory inside (and every .env/postgres_password file) stays
    # 0700/0600 owned by vibe:vibe. Without 0755 here, an unprivileged
    # operator running `vibe status` gets:
    #   [warn] no vibe configuration found at /etc/vibe/vibe.conf
    # because the parent dir's traversal is blocked even though the conf
    # itself is 0644. The 0750 default was over-tight for a single-tenant
    # CPA-firm appliance where the operator's account is the only
    # non-root user.
    install -d -m 0755 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_ETC"
    install -d -m 0755 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_DATA"
    install -d -m 0755 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_LOG"
    install -d -m 0700 -o "$VIBE_USER" -g "$VIBE_USER" "$VIBE_DATA/.archive"

    # On a re-run with pre-existing 0750 dirs (the previous default),
    # `install -d` with -m 0755 doesn't widen the mode — it only sets
    # mode at create time. Force it.
    chmod 0755 "$VIBE_ETC" "$VIBE_DATA" "$VIBE_LOG" 2>/dev/null || true
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
        # Existing config — backfill host_ip and ssh_user if missing,
        # leave everything else untouched (operator may have edited).
        local existing_ip
        existing_ip="$(grep -E '^host_ip=' "$conf" 2>/dev/null | cut -d= -f2)"
        if [ -z "$existing_ip" ]; then
            local detected_ip
            detected_ip="$(primary_ipv4 || true)"
            if [ -n "$detected_ip" ]; then
                if grep -q '^host_ip=' "$conf"; then
                    sed -i "s|^host_ip=.*|host_ip=${detected_ip}|" "$conf"
                else
                    printf 'host_ip=%s\n' "$detected_ip" >> "$conf"
                fi
                ok "config $conf — added host_ip=${detected_ip} (was missing)"
            fi
        fi
        if ! grep -qE '^ssh_user=' "$conf" 2>/dev/null; then
            local backfill_user="${SUDO_USER:-}"
            if [ -z "$backfill_user" ] && command -v logname >/dev/null 2>&1; then
                backfill_user="$(logname 2>/dev/null || true)"
            fi
            [ -z "$backfill_user" ] && backfill_user="vibe"
            printf 'ssh_user=%s\n' "$backfill_user" >> "$conf"
            ok "config $conf — added ssh_user=${backfill_user} (was missing)"
        fi
        ok "config $conf exists — backfilled missing fields, left rest untouched"
        return 0
    fi
    log "rendering $conf..."

    prompt_tls_intent
    # Globals set above: VIBE_TLS_MODE_PICK, VIBE_HOST_PICK, VIBE_ACME_EMAIL_PICK

    # Detect the appliance's primary LAN IPv4. Caddy will add this as a
    # SAN to the `tls internal` cert so Windows-only offices that can't
    # resolve vibe.local can still hit https://<ip>/ without
    # ERR_SSL_PROTOCOL_ERROR. No-op for acme / cf-tunnel modes (the
    # cert authority wouldn't issue for an IP anyway).
    local host_ip=""
    host_ip="$(primary_ipv4 || true)"

    # SSH user surfaced in the landing page's operator panel. Pick the
    # invoking operator (sudo) so the snippet works out of the box; fall
    # back to logname (real user even when sudo USER is `root`); fall
    # back to "vibe" so we never leave the field blank.
    local ssh_user="${SUDO_USER:-}"
    if [ -z "$ssh_user" ] && command -v logname >/dev/null 2>&1; then
        ssh_user="$(logname 2>/dev/null || true)"
    fi
    [ -z "$ssh_user" ] || [ "$ssh_user" = "root" ] && ssh_user="${ssh_user:-vibe}"

    install -m 0644 "$VIBE_PREFIX/etc/vibe.conf.template" "$conf"
    sed -i "s|^host=.*|host=${VIBE_HOST_PICK}|"          "$conf"
    sed -i "s|^host_ip=.*|host_ip=${host_ip}|"           "$conf"
    sed -i "s|^ssh_user=.*|ssh_user=${ssh_user}|"        "$conf"
    sed -i "s|^tls_mode=.*|tls_mode=${VIBE_TLS_MODE_PICK}|" "$conf"
    sed -i "s|^acme_email=.*|acme_email=${VIBE_ACME_EMAIL_PICK}|" "$conf"
    chown "$VIBE_USER:$VIBE_USER" "$conf"
    ok "wrote $conf (host=${VIBE_HOST_PICK}, host_ip=${host_ip:-<none>}, tls_mode=${VIBE_TLS_MODE_PICK}, mode=multi)"
}

# ---------- Bring up the Caddy ingress immediately ----------
# Always-multi-app deployment: Caddy at :80/:443 runs from the moment
# install.sh finishes. URLs stay stable forever — adding apps later does
# not move them. The 'vibe mode multi' subcommand is idempotent and brings
# up the ingress with the rendered Caddyfile, even when zero apps are
# installed (a landing page + /healthz is reachable).
#
# Failure here is fatal. The previous behavior was to `warn` and keep
# going, which left a half-bootstrapped state (no admin stack, missing
# render output) the user discovered later via `vibe status` saying
# "no vibe configuration found". verify_ports_free already catches the
# common port-collision case earlier, so reaching this branch usually
# means a docker/network problem the operator needs to fix anyway.
ensure_ingress() {
    log "starting Caddy ingress at :80/:443..."
    local out rc=0
    out="$("$VIBE_PREFIX/bin/vibe" mode multi 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "ingress is up"
    else
        printf '%s\n' "$out" >&2
        err "ingress failed to come up (rc=$rc)"
        warn "common causes: docker daemon down, ufw blocking, or a port:80 conflict"
        warn "  verify_ports_free passed earlier didn't detect — something started after."
        warn "after fixing the underlying issue, retry with: sudo vibe mode multi"
        die "aborting — ingress is required before continuing the bootstrap"
    fi
}

# ---------- Install the vibe-upgrade-check systemd timer ----------
# Drives the daily refresh of the landing page's "update available"
# data. See lib/ingress.sh::ingress_refresh_upgrade_check + the unit
# files at etc/systemd/system/vibe-upgrade-check.{service,timer}.
#
# Idempotent: re-running install.sh re-installs the units and re-enables
# the timer, but doesn't reset its OnBootSec / OnUnitActiveSec schedule.
ensure_upgrade_check_timer() {
    local svc="vibe-upgrade-check"
    local svc_target="/etc/systemd/system/${svc}.service"
    local timer_target="/etc/systemd/system/${svc}.timer"
    local svc_source="$VIBE_PREFIX/etc/systemd/system/${svc}.service"
    local timer_source="$VIBE_PREFIX/etc/systemd/system/${svc}.timer"

    if [ ! -f "$svc_source" ] || [ ! -f "$timer_source" ]; then
        warn "${svc}: unit files missing in $VIBE_PREFIX/etc/systemd/system/ — skipped"
        return 0
    fi

    install -m 0644 "$svc_source"   "$svc_target"
    install -m 0644 "$timer_source" "$timer_target"
    systemctl daemon-reload

    if systemctl enable --now "${svc}.timer" >/dev/null 2>&1; then
        ok "${svc}.timer: enabled (daily refresh of landing-page update data)"
    else
        warn "${svc}.timer: enable/start failed — check 'journalctl -u ${svc}.timer'"
    fi
}

# ---------- Migrate away from the old admin SPA + vibed daemon ----------
# Pre-2026-04 installs ran the Vibe-Admin SPA + a Go vibed daemon. Both
# are gone. This step idempotently tears them down on re-install:
#
#   - Stops + removes the vibe-admin compose project (drops the postgres
#     volume too — no archive, per the design choice).
#   - Removes /etc/vibe/admin/ + /var/lib/vibe/admin/ entirely.
#   - Disables + removes the vibed.service systemd unit.
#   - Removes the vibed binary + socket.
#
# No-op on a fresh install. Runs early in main() so the rest of the
# bootstrap sees a clean slate.
migrate_drop_admin() {
    local cleaned_anything=0

    # 1. Tear down the admin compose project if anything from it is around.
    if has_cmd docker; then
        if docker ps -a --filter 'name=^vibe-admin-' --format '{{.Names}}' 2>/dev/null \
                | grep -q .; then
            log "migrate: stopping the previous admin stack (data + postgres volume will be removed)..."
            # Use the project name + the original compose files when they're
            # still present. If the compose files are already gone (post-
            # delete), `docker compose --project-name vibe-admin down`
            # without `-f` still works because docker compose looks up the
            # project's containers by label.
            docker compose --project-name vibe-admin down --remove-orphans --volumes \
                >/dev/null 2>&1 || true
            cleaned_anything=1
        fi
    fi

    # 2. Drop config + data dirs.
    if [ -d "$VIBE_ETC/admin" ] || [ -d "$VIBE_DATA/admin" ]; then
        rm -rf "$VIBE_ETC/admin" "$VIBE_DATA/admin"
        cleaned_anything=1
    fi

    # 3. Disable + remove the vibed systemd unit + binary + socket.
    if [ -f /etc/systemd/system/vibed.service ] || [ -x /usr/local/bin/vibed ]; then
        systemctl disable --now vibed >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/vibed.service /usr/local/bin/vibed /run/vibed.sock
        systemctl daemon-reload >/dev/null 2>&1 || true
        cleaned_anything=1
    fi

    if [ "$cleaned_anything" -eq 1 ]; then
        ok "migrate: removed previous admin stack — control panel is now at https://<host>/"
    fi
}

# NOTE: `ensure_vibed` and `ensure_admin` lived here pre-2026-04. Both
# are gone — the admin SPA + vibed daemon were replaced by the static
# operator panel on the landing page. Migration of existing installs
# is handled by `migrate_drop_admin` above. The systemd timer that
# refreshes the landing page's update-available data is installed by
# `ensure_upgrade_check_timer` above.


# ---------- Post-install sanity check ----------
# Cheap end-of-bootstrap audit. Prevents a silently-half-baked state
# from slipping past us into print_next_steps. If any of these fail
# the operator gets a precise pointer instead of having to discover
# it via `vibe status` returning "no vibe configuration found" half
# an hour later.
verify_install() {
    log "verifying install state..."
    local errs=0

    # --- Required pieces (failure here is fatal) ---------------------
    # These must exist for the appliance to be usable AT ALL — no apps
    # can be installed without them.
    [ -f "$VIBE_ETC/vibe.conf" ] || { err "missing $VIBE_ETC/vibe.conf"; errs=$((errs+1)); }
    [ -L /usr/local/bin/vibe ]   || { err "missing symlink /usr/local/bin/vibe"; errs=$((errs+1)); }
    if ! docker network inspect "$VIBE_NETWORK" >/dev/null 2>&1; then
        err "missing docker network $VIBE_NETWORK"; errs=$((errs+1))
    fi
    if ! docker ps --filter 'name=^vibe-ingress-caddy$' --format '{{.Names}}' \
         | grep -qx vibe-ingress-caddy; then
        err "ingress container vibe-ingress-caddy is not running"; errs=$((errs+1))
    fi

    # --- Landing page data feeds -------------------------------------
    # The operator panel needs all three to render. ingress_render_caddyfile
    # writes installed.json + appliance.json on every render; the upgrade
    # check JSON is written by ensure_upgrade_check_timer's first run (or
    # populated lazily by the daily timer).
    [ -f "$VIBE_PREFIX/ingress/landing/__vibe_installed.json" ] \
        || { err "missing __vibe_installed.json (ingress render didn't run?)"; errs=$((errs+1)); }
    [ -f "$VIBE_PREFIX/ingress/landing/__vibe_appliance.json" ] \
        || { err "missing __vibe_appliance.json (ingress render didn't run?)"; errs=$((errs+1)); }

    if [ "$errs" -gt 0 ]; then
        err "install did not reach a healthy state ($errs check(s) failed)"
        err "run 'sudo vibe doctor' for a more detailed diagnostic"
        die "aborting before next-steps — fix the above and re-run install.sh"
    fi
    ok "install verified"
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

    # Caddy serves HTTPS in every mode — internal + cf-tunnel use a
    # self-signed cert (cloudflared connects with noTLSVerify in cf-tunnel
    # mode), acme uses a real Let's Encrypt cert. Both the hostname and
    # the LAN IP fallback are reachable over HTTPS.
    local host_scheme="https"
    local ip_scheme="https"

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
  The landing page at ${host_scheme}://${host}/ is the operator panel —
  it lists installed apps, shows which have updates available, and
  surfaces copy-pasteable SSH commands for installing/upgrading apps
  from this host.

  Install + manage apps from the command line:
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
    vibe status                       Installed apps + appliance state.
    sudo vibe doctor                  Run health checks.
    sudo vibe report                  Bundle install logs + state into one
                                      tarball you can send for support
                                      (secrets are auto-redacted).
    vibe help                         Full command reference.

  Config: $VIBE_ETC/vibe.conf
  Repo:   $VIBE_PREFIX
  Logs:   $VIBE_LOG/install-*.log  (this run: ${VIBE_INSTALL_LOG:-tee disabled})
          $VIBE_LOG/cli.log        (state-mutating vibe invocations)

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
    # Tear down any previous admin SPA + vibed daemon (idempotent — no-op
    # on a fresh install). Runs AFTER ensure_repo so $VIBE_PREFIX exists,
    # but BEFORE render_config so the rest of the bootstrap sees a clean
    # slate.
    migrate_drop_admin
    render_config
    ensure_ingress
    ensure_upgrade_check_timer
    verify_install
    print_next_steps
}

main "$@"
