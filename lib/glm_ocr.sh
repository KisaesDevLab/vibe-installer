#!/usr/bin/env bash
# GLM-OCR appliance lifecycle.
#
# `vibe install glm-ocr` brings up the self-contained OCR container at
# http://vibe-glm-ocr:8090 (reachable from inside vibe_ingress) and publishes
# 127.0.0.1:8090 on the host for local probes. MyBooks/TB consume it via
# their admin Settings UI; the installer doesn't auto-wire those.
#
# common.sh + config.sh sourced by callers.

GLM_OCR_PROJECT="${GLM_OCR_PROJECT:-vibe-glm-ocr}"
GLM_OCR_COMPOSE="${VIBE_PREFIX}/integrations/glm-ocr/docker-compose.yml"

glm_ocr_compose() {
    docker compose --project-name "$GLM_OCR_PROJECT" \
                   -f "$GLM_OCR_COMPOSE" "$@"
}

glm_ocr_install() {
    require_root
    log "preparing GLM-OCR appliance..."
    install -d -m 0750 -o "$VIBE_USER" -g "$VIBE_USER" \
        "${VIBE_DATA}/glm-ocr/cache"
    # vibe_ingress must exist (install.sh created it).
    docker network inspect "$VIBE_NETWORK" >/dev/null 2>&1 \
        || docker network create "$VIBE_NETWORK" >/dev/null

    log "pulling GLM-OCR image..."
    glm_ocr_compose pull --quiet || warn "image pull failed (will use cached if available)"

    log "starting GLM-OCR..."
    glm_ocr_compose up -d --remove-orphans

    log "waiting for GLM-OCR to load the model (up to 3 min)..."
    local deadline=$(( $(date +%s) + 200 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS --max-time 3 http://127.0.0.1:8090/health >/dev/null 2>&1; then
            ok "GLM-OCR is healthy at http://127.0.0.1:8090/"
            log "  apps reach it on the internal network as http://vibe-glm-ocr:8090"
            return 0
        fi
        sleep 5
    done
    warn "GLM-OCR did not report healthy in time — check 'vibe logs glm-ocr' (runs '${GLM_OCR_PROJECT}' compose project)"
    return 1
}

glm_ocr_uninstall() {
    require_root
    log "stopping GLM-OCR..."
    glm_ocr_compose down --remove-orphans
    # Cache decision tree:
    #   VIBE_GLM_OCR_KEEP_CACHE=1   → preserve unconditionally. Used by
    #                                  the admin UI when the operator
    #                                  doesn't tick "also delete cache".
    #   VIBE_GLM_OCR_DELETE_CACHE=1 → delete unconditionally. Used by
    #                                  the admin UI when the box IS
    #                                  ticked.
    #   neither set                 → fall through to interactive
    #                                  confirm. Note vibed always sets
    #                                  VIBE_ASSUME_YES=1, so a daemon
    #                                  caller that doesn't set one of
    #                                  the two flags above would silently
    #                                  delete a multi-GB cache. The
    #                                  flags exist to make that decision
    #                                  explicit.
    if [ "${VIBE_GLM_OCR_KEEP_CACHE:-0}" = "1" ]; then
        ok "model cache preserved at ${VIBE_DATA}/glm-ocr/cache"
        return 0
    fi
    if [ "${VIBE_GLM_OCR_DELETE_CACHE:-0}" = "1" ]; then
        rm -rf "${VIBE_DATA}/glm-ocr"
        ok "model cache removed"
        return 0
    fi
    if confirm "Remove the model cache at ${VIBE_DATA}/glm-ocr/cache? This forces a multi-GB re-download next install. [y/N] " no; then
        rm -rf "${VIBE_DATA}/glm-ocr"
        ok "model cache removed"
    else
        ok "model cache preserved at ${VIBE_DATA}/glm-ocr/cache"
    fi
}

glm_ocr_status() {
    if docker ps --filter 'name=^vibe-glm-ocr$' --format '{{.Names}}' 2>/dev/null \
        | grep -qx vibe-glm-ocr; then
        local health
        health="$(docker inspect -f '{{.State.Health.Status}}' vibe-glm-ocr 2>/dev/null || echo unknown)"
        ok "GLM-OCR running (health: ${health}) at http://127.0.0.1:8090/"
    else
        warn "GLM-OCR is not running (install with: sudo vibe install glm-ocr)"
    fi
}
