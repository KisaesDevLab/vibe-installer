#!/usr/bin/env bash
# vibe-installer common helpers — sourced by bin/vibe and other lib/*.sh files.
# Strict mode is set by callers; this file only adds helpers.

# ---------- Paths ----------
VIBE_PREFIX="${VIBE_PREFIX:-/opt/vibe-installer}"
VIBE_ETC="${VIBE_ETC:-/etc/vibe}"
VIBE_DATA="${VIBE_DATA:-/var/lib/vibe}"
VIBE_LOG="${VIBE_LOG:-/var/log/vibe}"
VIBE_CONF="${VIBE_CONF:-${VIBE_ETC}/vibe.conf}"
VIBE_LOCK="${VIBE_LOCK:-/var/run/vibe.lock}"
VIBE_NETWORK="${VIBE_NETWORK:-vibe_ingress}"
VIBE_USER="${VIBE_USER:-vibe}"

# ---------- Logging ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'
    _C_GRN=$'\033[32m'; _C_BLU=$'\033[34m'; _C_DIM=$'\033[2m'
else
    _C_RESET=""; _C_RED=""; _C_YEL=""; _C_GRN=""; _C_BLU=""; _C_DIM=""
fi

log()  { printf '%s[vibe]%s %s\n' "$_C_BLU" "$_C_RESET" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$_C_GRN" "$_C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$_C_YEL" "$_C_RESET" "$*" >&2; }
err()  { printf '%s[err ]%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
dbg()  { [ -n "${VIBE_DEBUG:-}" ] && printf '%s[dbg ] %s%s\n' "$_C_DIM" "$*" "$_C_RESET" >&2 || true; }

# ---------- Privilege ----------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "this command must run as root (try: sudo $0 $*)"
}

# ---------- Confirmation prompt (TTY-aware) ----------
# confirm "Continue? [Y/n] "  -> returns 0 on yes, 1 on no
# Non-interactive: honors VIBE_ASSUME_YES=1 (yes) or default-no.
confirm() {
    local prompt="${1:-Continue? [y/N] }"
    local default_yes="${2:-no}"
    if [ "${VIBE_ASSUME_YES:-0}" = "1" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        # No TTY — fall back to default
        [ "$default_yes" = "yes" ] && return 0 || return 1
    fi
    local reply
    read -rp "$prompt" reply
    case "$reply" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        "") [ "$default_yes" = "yes" ] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

# ---------- Lock ----------
# Wraps a function/command in a flock so two `vibe` invocations can't race.
with_lock() {
    local lock_fd=9
    mkdir -p "$(dirname "$VIBE_LOCK")"
    eval "exec ${lock_fd}>>\"$VIBE_LOCK\""
    if ! flock -n "$lock_fd"; then
        die "another vibe operation is in progress (lock: $VIBE_LOCK)"
    fi
    "$@"
    local rc=$?
    eval "exec ${lock_fd}>&-"
    return $rc
}

# ---------- Command existence ----------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    has_cmd "$1" || die "required command not found: $1"
}

# ---------- OS / arch detection ----------
os_id() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${ID:-unknown}"
    else
        printf 'unknown\n'
    fi
}

os_version() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${VERSION_ID:-unknown}"
    else
        printf 'unknown\n'
    fi
}

arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) printf '%s\n' "$(uname -m)" ;;
    esac
}

# ---------- Disk / RAM checks ----------
free_mem_gb() {
    awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo
}

free_disk_gb() {
    local path="${1:-/var}"
    df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -d 'G ' || echo 0
}

# ---------- machine-id (stable host fingerprint for license trial) ----------
machine_id() {
    if [ -r /etc/machine-id ]; then
        cat /etc/machine-id
    elif [ -r /var/lib/dbus/machine-id ]; then
        cat /var/lib/dbus/machine-id
    else
        # Last resort: hash the primary MAC
        ip link 2>/dev/null | awk '/link\/ether/ { print $2; exit }' | sha256sum | cut -d' ' -f1
    fi
}
