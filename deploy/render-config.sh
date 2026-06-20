#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
sed "s/__TUNNEL_ID__/${TUNNEL_ID}/g" \
  "$HERE/cloudflared/config.yml.template" > "$HERE/cloudflared/config.yml"
echo "rendered $HERE/cloudflared/config.yml"
