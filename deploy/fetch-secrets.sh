#!/usr/bin/env bash
# Fetch app secrets from the Cloudflare broker (Access service token) → podman secrets.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/config.env"
: "${CF_SERVICE_TOKEN_ID:?service token id required}"
: "${CF_SERVICE_TOKEN_SECRET:?service token secret required}"

JSON="$(curl -fsS "https://$SECRETS_DOMAIN/secrets" \
  -H "CF-Access-Client-Id: $CF_SERVICE_TOKEN_ID" \
  -H "CF-Access-Client-Secret: $CF_SERVICE_TOKEN_SECRET")"

put() { # name <- json key
  local secret="$1" key="$2" val
  val="$(printf '%s' "$JSON" | jq -er ".$key")"
  printf '%s' "$val" | podman secret rm "$secret" >/dev/null 2>&1 || true
  printf '%s' "$val" | podman secret create "$secret" - >/dev/null
}
put "$SECRET_JWT"        JWT_SECRET
put "$SECRET_ENCKEY"     ENCRYPTION_KEY
put "$SECRET_GH_ID"      GITHUB_CLIENT_ID
put "$SECRET_GH_SECRET"  GITHUB_CLIENT_SECRET
put "$SECRET_TUNNEL"     TUNNEL_CRED

# No ghcr login — images are public, pulled anonymously.
echo "[fetch-secrets] podman secrets created"
