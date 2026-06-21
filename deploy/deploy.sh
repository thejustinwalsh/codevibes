#!/usr/bin/env bash
# CodeVibes deploy/rollback. Pulls newer ghcr tag, smoke-tests, swaps :current, records state.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
STATE_DIR="${DEPLOY_STATE_DIR:-$DATA_MOUNT}"
STATE="$STATE_DIR/deploy-state"
mkdir -p "$STATE_DIR"

log() { echo "[deploy] $*"; }

current_tag() { [ -f "$STATE" ] && (grep '^CURRENT=' "$STATE" | cut -d= -f2) || echo ""; }
previous_tag() { [ -f "$STATE" ] && (grep '^PREVIOUS=' "$STATE" | cut -d= -f2) || echo ""; }

# List remote tags via the ghcr REST API (public images, anonymous token).
# Uses curl+jq (already installed by cloud-init) — no skopeo dependency.
latest_remote_tag() {
  local repo token
  repo="${IMAGE_BACKEND#ghcr.io/}"   # e.g. thejustinwalsh/codevibes-backend
  token="$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r '.token')"
  curl -fsS -H "Authorization: Bearer ${token}" "https://ghcr.io/v2/${repo}/tags/list" \
    | jq -r '.tags[]?' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1
}

# Smoke test: boot the candidate backend against the REAL data volume (read-write)
# with the real podman secrets, and poll /api/health. This works on first deploy
# (the backend creates the DB on the volume if absent) and still catches a broken
# mount or corrupt DB (the backend fails to boot → health never comes up → fail).
smoke_test() {
  local tag="$1" ok=1 i
  if [ "${DEPLOY_SMOKE_OVERRIDE:-}" = "pass" ]; then return 0; fi
  if [ "${DEPLOY_SMOKE_OVERRIDE:-}" = "fail" ]; then return 1; fi
  podman rm -f codevibes-smoke >/dev/null 2>&1 || true
  podman run -d --name codevibes-smoke \
    -e NODE_ENV=production -e PORT=3001 -e DB_PATH=/app/data/codevibes.db \
    --secret "${SECRET_JWT},type=env,target=JWT_SECRET" \
    --secret "${SECRET_ENCKEY},type=env,target=ENCRYPTION_KEY" \
    -v "$DATA_MOUNT":/app/data:Z \
    -p 127.0.0.1:3099:3001 \
    "$IMAGE_BACKEND:$tag" >/dev/null
  for i in $(seq 1 20); do
    if curl -fsS http://127.0.0.1:3099/api/health >/dev/null 2>&1; then ok=0; break; fi
    sleep 1
  done
  podman logs codevibes-smoke 2>&1 | tail -5 || true
  podman rm -f codevibes-smoke >/dev/null 2>&1 || true
  return $ok
}

swap_to() { # retarget the floating :current tags + restart pod
  local tag="$1"
  podman pull "$IMAGE_BACKEND:$tag"
  podman pull "$IMAGE_WEB:$tag"
  podman tag "$IMAGE_BACKEND:$tag" "localhost/codevibes-backend:current"
  podman tag "$IMAGE_WEB:$tag" "localhost/codevibes-web:current"
  systemctl --user daemon-reload 2>/dev/null || true
  # Restart the CONTAINER services (not just the pod): with Quadlet each container is
  # its own service and pulls in the pod + volume as dependencies. Restarting only the
  # pod service would leave the containers down. `restart` also starts them on first run.
  systemctl --user restart codevibes-backend.service codevibes-web.service codevibes-cloudflared.service 2>/dev/null || true
}

record_state() { printf 'CURRENT=%s\nPREVIOUS=%s\n' "$1" "$2" > "$STATE"; }

do_rollback() {
  local prev; prev="$(previous_tag)"
  [ -n "$prev" ] || { log "no previous tag to roll back to"; exit 1; }
  log "rolling back to $prev"
  swap_to "$prev"
  record_state "$prev" ""
  log "rollback complete"
}

main() {
  if [ "${1:-}" = "--rollback" ]; then do_rollback; return; fi
  local cur new; cur="$(current_tag)"; new="$(latest_remote_tag)"
  [ -n "$new" ] || { log "no remote tags found"; exit 1; }
  if [ "$new" = "$cur" ]; then log "already on $cur; nothing to do"; return 0; fi
  log "candidate $new (current: ${cur:-none})"
  podman pull "$IMAGE_BACKEND:$new"
  if ! smoke_test "$new"; then
    log "SMOKE TEST FAILED for $new — keeping ${cur:-current}, not swapping"
    exit 1
  fi
  swap_to "$new"
  record_state "$new" "$cur"
  log "deployed $new"
}
main "$@"
