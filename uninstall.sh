#!/usr/bin/env bash
# vibe-installer — host uninstall.
#
# Inverse of install.sh. Runs `vibe uninstall --all` first to archive every
# app's data, then optionally removes:
#   - /opt/vibe-installer (this repo)
#   - /usr/local/bin/vibe (the symlink)
#   - the `vibe` system user
#   - /etc/vibe (config)
#   - /var/lib/vibe (per-app data — by default leaves the .archive subdir alone)
#   - Docker itself (only on explicit confirm)
#
# Volume archives under /var/lib/vibe/.archive/ are NEVER auto-deleted by
# this script. The operator removes them manually.

set -euo pipefail

VIBE_PREFIX="${VIBE_PREFIX:-/opt/vibe-installer}"
VIBE_ETC="${VIBE_ETC:-/etc/vibe}"
VIBE_DATA="${VIBE_DATA:-/var/lib/vibe}"
VIBE_USER="${VIBE_USER:-vibe}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _R=$'\033[0m'; _RED=$'\033[31m'; _YEL=$'\033[33m'; _GRN=$'\033[32m'; _BLU=$'\033[34m'
else
    _R=""; _RED=""; _YEL=""; _GRN=""; _BLU=""
fi
log()  { printf '%s[uninstall]%s %s\n' "$_BLU" "$_R" "$*"; }
ok()   { printf '%s[   ok    ]%s %s\n' "$_GRN" "$_R" "$*"; }
warn() { printf '%s[  warn   ]%s %s\n' "$_YEL" "$_R" "$*" >&2; }
die()  { printf '%s[  error  ]%s %s\n' "$_RED" "$_R" "$*" >&2; exit 1; }

confirm() {
    local prompt="${1:-Continue? [y/N] }"
    if [ "${VIBE_ASSUME_YES:-0}" = "1" ]; then return 0; fi
    if [ ! -t 0 ]; then return 1; fi
    local reply
    read -rp "$prompt" reply
    case "$reply" in [Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"

log "vibe-installer host teardown"

# 1. Tear down apps via the CLI.
if [ -x "$VIBE_PREFIX/bin/vibe" ]; then
    log "running 'vibe uninstall --all' (this archives volumes; nothing is force-deleted)..."
    VIBE_ASSUME_YES="${VIBE_ASSUME_YES:-1}" "$VIBE_PREFIX/bin/vibe" uninstall --all || \
        warn "vibe uninstall --all returned non-zero — continuing"
fi

# 2. Remove the symlink.
if [ -L /usr/local/bin/vibe ]; then
    rm -f /usr/local/bin/vibe && ok "removed /usr/local/bin/vibe"
fi

# 3. Remove the installer repo.
if [ -d "$VIBE_PREFIX" ]; then
    if confirm "Remove $VIBE_PREFIX (this installer repo)? [y/N] "; then
        rm -rf "$VIBE_PREFIX"
        ok "removed $VIBE_PREFIX"
    else
        warn "left $VIBE_PREFIX in place"
    fi
fi

# 4. Remove /etc/vibe (config + license cache + per-app envs).
if [ -d "$VIBE_ETC" ]; then
    if confirm "Remove $VIBE_ETC (config + secrets)? [y/N] "; then
        rm -rf "$VIBE_ETC"
        ok "removed $VIBE_ETC"
    else
        warn "left $VIBE_ETC in place"
    fi
fi

# 5. Remove /var/lib/vibe (data). By default we keep /var/lib/vibe/.archive
#    so app archives survive a host teardown.
if [ -d "$VIBE_DATA" ]; then
    if confirm "Remove $VIBE_DATA but KEEP $VIBE_DATA/.archive? [y/N] "; then
        find "$VIBE_DATA" -mindepth 1 -maxdepth 1 ! -name '.archive' -exec rm -rf {} + 2>/dev/null || true
        ok "removed $VIBE_DATA contents (archives preserved)"
    elif confirm "Remove $VIBE_DATA in full (including archives)? [y/N] "; then
        rm -rf "$VIBE_DATA"
        ok "removed $VIBE_DATA in full"
    else
        warn "left $VIBE_DATA in place"
    fi
fi

# 6. Remove the vibe user.
if id "$VIBE_USER" >/dev/null 2>&1; then
    if confirm "Remove the '$VIBE_USER' system user? [y/N] "; then
        userdel "$VIBE_USER" 2>/dev/null || true
        groupdel "$VIBE_USER" 2>/dev/null || true
        ok "removed user $VIBE_USER"
    fi
fi

# 7. Optionally remove Docker — separate confirm because it's host-wide.
if command -v docker >/dev/null 2>&1; then
    if confirm "Remove Docker engine + CLI from this host? [y/N] "; then
        apt-get -y purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
        rm -rf /var/lib/docker /var/lib/containerd
        ok "Docker removed"
    fi
fi

ok "host teardown complete"
