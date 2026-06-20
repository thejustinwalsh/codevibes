#!/usr/bin/env bash
# Fallback: create podman secrets by hand if the broker is unreachable.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
prompt() { local var="$1" msg="$2" v; read -rsp "$msg: " v; echo; printf '%s' "$v" | podman secret create "$var" - ; }
echo "Manual secret bootstrap (fallback). Values are not echoed."
prompt "$SECRET_JWT"        "JWT_SECRET"
prompt "$SECRET_ENCKEY"     "ENCRYPTION_KEY (32 chars, NEVER regenerate)"
prompt "$SECRET_GH_ID"      "GITHUB_CLIENT_ID"
prompt "$SECRET_GH_SECRET"  "GITHUB_CLIENT_SECRET"
echo "Paste tunnel credential JSON, end with Ctrl-D:"; podman secret create "$SECRET_TUNNEL" -
# No ghcr login — images are public.
echo "[bootstrap] done"
