#!/usr/bin/env bash
# Nightly SQLite backup on the volume; retain last 7.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
DB="${DB_PATH:-$DATA_MOUNT/codevibes.db}"
DEST="$DATA_MOUNT/backups"
mkdir -p "$DEST"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
sqlite3 "$DB" ".backup '$DEST/codevibes-$STAMP.db'"
find "$DEST" -maxdepth 1 -name 'codevibes-*.db' -printf '%T@ %p\n' \
  | sort -rn | tail -n +8 | cut -d' ' -f2- | xargs -r rm -f
echo "[backup] wrote $DEST/codevibes-$STAMP.db"
