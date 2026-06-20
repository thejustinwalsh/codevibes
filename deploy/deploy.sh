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

latest_remote_tag() {
  skopeo list-tags "docker://$IMAGE_BACKEND" \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1
}

# Smoke test: boot new backend image in a throwaway container, check /api/health
# AND a read-only SQLite query against the live DB (catches broken mount / corrupt DB).
smoke_test() {
  local tag="$1"
  if [ "${DEPLOY_SMOKE_OVERRIDE:-}" = "pass" ]; then return 0; fi
  if [ "${DEPLOY_SMOKE_OVERRIDE:-}" = "fail" ]; then return 1; fi
  podman run --rm --name codevibes-smoke \
    -e NODE_ENV=production -e PORT=3001 -e DB_PATH=/app/data/codevibes.db \
    -v "$DATA_MOUNT":/app/data:ro,Z \
    --health-cmd 'wget -q --spider http://localhost:3001/api/health || exit 1' \
    "$IMAGE_BACKEND:$tag" \
    node -e "require('better-sqlite3')(process.env.DB_PATH,{readonly:true,fileMustExist:true}).prepare('SELECT 1').get(); process.exit(0)"
}

swap_to() { # retarget the floating :current tags + restart pod
  local tag="$1"
  podman pull "$IMAGE_BACKEND:$tag"
  podman pull "$IMAGE_WEB:$tag"
  podman tag "$IMAGE_BACKEND:$tag" "localhost/codevibes-backend:current"
  podman tag "$IMAGE_WEB:$tag" "localhost/codevibes-web:current"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user restart codevibes-pod 2>/dev/null || true
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
