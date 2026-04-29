#!/usr/bin/env bash
# `vibe report` — bundle everything an operator would need to send for
# triage when something on the appliance isn't working. Output is a
# single tarball at /var/lib/vibe/.archive/report-<ts>.tar.gz.
#
# What goes in:
#   1. install.sh's tee'd log (the most recent /var/log/vibe/install-*.log)
#   2. The CLI activity log (/var/log/vibe/cli.log) — last N invocations
#   3. /etc/vibe/vibe.conf (config; non-secret)
#   4. SANITIZED env files: redact LICENSE_TOKEN, *_PASSWORD, *_SECRET,
#      *_KEY, *_TOKEN before including
#   5. `docker ps -a`, `docker network ls`, `docker volume ls` snapshots
#   6. `vibe status` + `vibe doctor` output (if root, full; otherwise partial)
#   7. `docker logs --tail 200` for every running vibe-* container
#   8. Host fingerprint: uname, /etc/os-release, free, df -h, ss -tlnp on
#      :80/:443, systemctl status caddy/vibed (if applicable)
#
# What's deliberately NOT in:
#   - Per-app data (postgres, uploads) — too big and contains business data
#   - Caddy's PKI directory (private CA root key)
#   - License public key (operator-specific, not useful for triage)

# common.sh sourced by caller.

REPORT_DIR_DEFAULT="${VIBE_DATA}/.archive"

# Sensitive-key redactor — overwrites the value side of any KEY=VALUE
# pair where KEY matches the well-known secret patterns. Used on .env
# files before bundling.
_redact_env() {
    sed -E 's/^([A-Z_]*(PASSWORD|SECRET|KEY|TOKEN|AUTHKEY|API_KEY)[A-Z_]*)=.*/\1=***REDACTED***/'
}

# Run a command, capturing both stdout and stderr, prefixed with a header.
# Never fails (so a missing tool / non-root call doesn't kill the report).
_capture() {
    local label="$1"; shift
    {
        printf '\n========== %s ==========\n' "$label"
        printf '$ %s\n' "$*"
        "$@" 2>&1 || printf '(exit code: %d)\n' "$?"
    }
}

report_bundle() {
    require_root || die "vibe report requires root (it reads /etc/vibe/* secrets to redact + bundle)"

    # Parse flags. The default output dir is /var/lib/vibe/.archive/ which
    # is mode 0700 owned by `vibe` — fine for on-host inspection, but
    # blocks an SSH user from `scp`-ing the file off the box without sudo.
    # `--for-download` flips the output to /tmp/ + mode 0644, prints the
    # exact scp command the operator should paste from their workstation.
    local for_download=0 out_dir=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --for-download) for_download=1; shift ;;
            -*) warn "ignoring unknown flag: $1"; shift ;;
            *)  out_dir="$1"; shift ;;
        esac
    done

    if [ "$for_download" = "1" ]; then
        out_dir="${out_dir:-/tmp}"
    else
        out_dir="${out_dir:-$REPORT_DIR_DEFAULT}"
    fi

    if [ "$for_download" = "1" ] && [ "$out_dir" = "/tmp" ]; then
        : # /tmp already exists with the right perms
    else
        install -d -m 0700 -o "$VIBE_USER" -g "$VIBE_USER" "$out_dir"
    fi

    local ts staging tarball
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    staging="$(mktemp -d "${TMPDIR:-/tmp}/vibe-report-${ts}.XXXXXX")"
    tarball="${out_dir}/report-${ts}.tar.gz"

    log "collecting diagnostics into ${staging}/ ..."

    # --- 1. install.sh log (most recent run) ---
    local latest_install_log
    latest_install_log="$(ls -1t "$VIBE_LOG"/install-*.log 2>/dev/null | head -1 || true)"
    if [ -n "$latest_install_log" ]; then
        cp "$latest_install_log" "$staging/install.log"
        ok "  ✓ install log: $(basename "$latest_install_log")"
    else
        printf '(no install-*.log found in %s)\n' "$VIBE_LOG" > "$staging/install.log"
    fi

    # --- 2. CLI activity log (tail to keep size sane) ---
    if [ -f "$VIBE_LOG/cli.log" ]; then
        # Keep the last ~5000 lines — enough for 50+ commands
        tail -n 5000 "$VIBE_LOG/cli.log" > "$staging/cli.log"
        ok "  ✓ cli log: $(wc -l < "$staging/cli.log") lines"
    else
        printf '(no cli.log)\n' > "$staging/cli.log"
    fi

    # --- 3. vibe.conf (non-secret) ---
    if [ -f "$VIBE_CONF" ]; then
        cp "$VIBE_CONF" "$staging/vibe.conf"
        ok "  ✓ vibe.conf"
    else
        printf '(no vibe.conf)\n' > "$staging/vibe.conf"
    fi

    # --- 4. Per-app .env files (redacted) ---
    install -d "$staging/etc-vibe-redacted"
    local app_env
    for app_env in "$VIBE_ETC"/*/.env "$VIBE_ETC/ingress/.env" "$VIBE_ETC/tools/.env"; do
        [ -f "$app_env" ] || continue
        local rel="${app_env#$VIBE_ETC/}"
        local dest="$staging/etc-vibe-redacted/$rel"
        install -d "$(dirname "$dest")"
        _redact_env < "$app_env" > "$dest"
    done
    ok "  ✓ /etc/vibe/*/.env (with secret values redacted)"

    # --- 5. Docker state ---
    {
        _capture "docker version"           docker version
        _capture "docker info"              docker info --format '{{json .}}'
        _capture "docker ps -a"             docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
        _capture "docker network ls"        docker network ls
        _capture "docker network inspect $VIBE_NETWORK"  docker network inspect "$VIBE_NETWORK"
        _capture "docker volume ls"         docker volume ls
    } > "$staging/docker-state.txt" 2>&1
    ok "  ✓ docker state"

    # --- 6. vibe status + doctor ---
    {
        _capture "vibe version"  "$VIBE_PREFIX/bin/vibe" version
        _capture "vibe status"   "$VIBE_PREFIX/bin/vibe" status
        _capture "vibe doctor"   "$VIBE_PREFIX/bin/vibe" doctor
        _capture "vibe mode"     "$VIBE_PREFIX/bin/vibe" mode
    } > "$staging/vibe-state.txt" 2>&1
    ok "  ✓ vibe status / doctor / mode"

    # --- 7. Per-container logs (last 200 lines each) ---
    install -d "$staging/container-logs"
    local cname
    while IFS= read -r cname; do
        [ -z "$cname" ] && continue
        # Sanitize filename (Docker container names are safe but just in case)
        local sf
        sf="$(printf '%s' "$cname" | tr '/' '_').log"
        docker logs --tail 200 "$cname" > "$staging/container-logs/$sf" 2>&1 || true
    done < <(docker ps -a --filter 'name=vibe' --format '{{.Names}}' 2>/dev/null)
    # Also grab vibept-* (Payroll uses that naming).
    while IFS= read -r cname; do
        [ -z "$cname" ] && continue
        local sf
        sf="$(printf '%s' "$cname" | tr '/' '_').log"
        docker logs --tail 200 "$cname" > "$staging/container-logs/$sf" 2>&1 || true
    done < <(docker ps -a --filter 'name=vibept' --format '{{.Names}}' 2>/dev/null)
    local nlogs
    nlogs="$(ls "$staging/container-logs" 2>/dev/null | wc -l | tr -d ' ')"
    ok "  ✓ container logs (${nlogs} containers, last 200 lines each)"

    # --- 8. Host fingerprint ---
    {
        _capture "uname -a"          uname -a
        _capture "/etc/os-release"   cat /etc/os-release
        _capture "free -h"           free -h
        _capture "df -h /var /opt /tmp"   df -h /var /opt /tmp
        _capture "ss -tlnp on :80/:443"   sh -c "ss -tlnp 2>/dev/null | awk 'NR==1 || \$4 ~ /:(80|443)\$/'"
        _capture "systemctl status docker"  systemctl status docker --no-pager --lines 5
        _capture "systemctl status caddy"   systemctl status caddy --no-pager --lines 5
        _capture "systemctl status vibed"   systemctl status vibed --no-pager --lines 5
    } > "$staging/host-fingerprint.txt" 2>&1
    ok "  ✓ host fingerprint"

    # --- 9. Repo HEAD info ---
    {
        printf 'VIBE_PREFIX=%s\n' "$VIBE_PREFIX"
        if [ -d "$VIBE_PREFIX/.git" ]; then
            printf 'git HEAD: %s\n' "$(git -C "$VIBE_PREFIX" rev-parse HEAD 2>/dev/null || echo unknown)"
            printf 'git branch: %s\n' "$(git -C "$VIBE_PREFIX" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
            git -C "$VIBE_PREFIX" log --oneline -10 2>/dev/null
        else
            printf '(no .git directory at %s)\n' "$VIBE_PREFIX"
        fi
    } > "$staging/installer-version.txt"

    # --- 10. README for the recipient ---
    cat > "$staging/README.txt" <<EOF
Vibe appliance diagnostic bundle
================================
Generated: $(date -Is)
Hostname:  $(hostname)
Repo HEAD: $(git -C "$VIBE_PREFIX" rev-parse --short HEAD 2>/dev/null || echo unknown)

Send the entire .tar.gz file (NOT just one of these files) — the
filenames are linked across the bundle.

Files:
  install.log              Most recent install.sh run output.
  cli.log                  Recent \`vibe ...\` invocations (state-mutating).
  vibe.conf                /etc/vibe/vibe.conf (non-secret).
  etc-vibe-redacted/       Per-app .env files with PASSWORD/SECRET/KEY/TOKEN
                           values redacted.
  docker-state.txt         docker ps/network/volume snapshots.
  vibe-state.txt           vibe status, vibe doctor, vibe mode.
  container-logs/          Last 200 lines of each Vibe container's logs.
  host-fingerprint.txt     Host info: kernel, OS, RAM, disk, listening ports.
  installer-version.txt    git HEAD of /opt/vibe-installer.

What was NOT included:
  - Per-app data (Postgres dumps, file uploads).
  - Caddy's PKI directory (private CA root key).
  - License token + secrets — those are redacted.

If anything in this bundle still contains data you don't want to share,
edit the .tar.gz before sending.
EOF

    log "tarring up..."
    ( cd "$staging" && tar -czf "$tarball" . )
    rm -rf "$staging"

    if [ "$for_download" = "1" ]; then
        # SSH-download path: world-readable so `scp adminvibe@host:...`
        # works without sudo. Secrets are already redacted in the bundle,
        # so 0644 doesn't expand the attack surface beyond on-host
        # inspection — anyone who can read /tmp could already see
        # everything in /etc/vibe/*/.env directly.
        chmod 0644 "$tarball"
    else
        chown "$VIBE_USER:$VIBE_USER" "$tarball" 2>/dev/null || true
        chmod 0600 "$tarball"
    fi

    echo
    ok "report bundled to:"
    echo "    $tarball"
    echo "    size: $(du -h "$tarball" | cut -f1)"
    echo
    if [ "$for_download" = "1" ]; then
        # Detect the appliance's primary IPv4 so we can pre-fill the scp
        # example. Falls back to <host> placeholder if detection fails.
        local ip
        ip="$(ip -4 -o addr show scope global 2>/dev/null \
              | awk '{ split($4, a, "/"); print a[1]; exit }' || true)"
        [ -z "$ip" ] && ip="<appliance-ip>"
        local user="${SUDO_USER:-<your-ssh-user>}"
        echo
        log "to download from your workstation, paste either of these:"
        echo
        echo "    # scp (any platform with OpenSSH client):"
        echo "    scp ${user}@${ip}:${tarball} ."
        echo
        echo "    # rsync (resumable; useful for large bundles):"
        echo "    rsync -avzP ${user}@${ip}:${tarball} ."
        echo
        log "after the file is on your workstation, you can clean it up here:"
        echo "    rm ${tarball}"
    else
        log "send this file when you ask for help — it answers most triage questions in one shot."
        log "to download from SSH (file is mode 0600, owned by ${VIBE_USER}):"
        log "  re-run with the --for-download flag, OR"
        log "  ssh <user>@<host> \"sudo cat ${tarball}\" > vibe-report.tar.gz"
    fi
}
