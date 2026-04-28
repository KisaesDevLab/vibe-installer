#!/usr/bin/env bash
# Tailscale enrollment for the host.
#
# `vibe install tailscale` installs the Tailscale CLI (if missing) and runs
# `tailscale up --ssh --accept-dns`. The 10-min `timeout` ceiling lifted from
# Vibe-Linux-Setup/provision.sh:945-981 keeps unattended installs from
# hanging forever — operators who miss the auth window resume manually.
#
# Unattended path: set TAILSCALE_AUTHKEY=tskey-... before running.
#
# common.sh sourced by caller.

tailscale_install() {
    require_root

    if ! has_cmd tailscale; then
        log "installing Tailscale via official install script..."
        curl -fsSL https://tailscale.com/install.sh | sh
        ok "Tailscale CLI installed"
    else
        ok "Tailscale CLI already installed: $(tailscale version 2>/dev/null | head -1)"
    fi

    # If we're already logged in, surface the IP and exit.
    if tailscale status --self=true --peers=false >/dev/null 2>&1 \
        && [ "$(tailscale status --self=true --peers=false --json 2>/dev/null | grep -c '"BackendState":"Running"')" -gt 0 ]; then
        ok "Tailscale already authenticated; IP: $(tailscale ip -4 2>/dev/null | head -1)"
        return 0
    fi

    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        log "authenticating with provided TAILSCALE_AUTHKEY..."
        if tailscale up --ssh --accept-dns --auth-key="$TAILSCALE_AUTHKEY"; then
            ok "Tailscale up; IP: $(tailscale ip -4 2>/dev/null | head -1)"
            return 0
        fi
        die "tailscale up --auth-key failed; verify the key at https://login.tailscale.com/admin/settings/keys"
    fi

    if [ ! -t 0 ]; then
        warn "no TAILSCALE_AUTHKEY set and no TTY — skipping enrollment."
        warn "resume later with: sudo tailscale up --ssh --accept-dns"
        return 0
    fi

    cat <<'EOM'

  Tailscale will print a URL — paste it into a browser, sign in, and
  authorize this host. The 10-minute ceiling means this window won't
  hang the installer if you walk away.

EOM

    if ! command -v timeout >/dev/null 2>&1; then
        warn "GNU timeout not found — running tailscale up without a ceiling"
        tailscale up --ssh --accept-dns || warn "tailscale up returned non-zero"
        return 0
    fi

    set +e
    timeout 600 tailscale up --ssh --accept-dns
    local rc=$?
    set -e
    case "$rc" in
        0)   ok "Tailscale up; IP: $(tailscale ip -4 2>/dev/null | head -1)" ;;
        124) warn "Tailscale auth window timed out after 10 min — resume with: sudo tailscale up --ssh --accept-dns" ;;
        *)   warn "tailscale up returned exit code $rc" ;;
    esac
}

tailscale_uninstall() {
    require_root
    if ! has_cmd tailscale; then
        ok "Tailscale CLI not present; nothing to remove"
        return 0
    fi
    log "stopping tailscaled and unregistering this host..."
    tailscale logout 2>/dev/null || true
    systemctl stop tailscaled 2>/dev/null || true
    if confirm "Remove the Tailscale CLI from this host (apt purge)? [y/N] " no; then
        apt-get -y purge tailscale tailscale-archive-keyring >/dev/null 2>&1 || true
        ok "Tailscale removed"
    fi
}

tailscale_status() {
    if has_cmd tailscale; then
        tailscale status 2>&1 | head -10
    else
        warn "Tailscale CLI not installed (sudo vibe install tailscale)"
    fi
}
