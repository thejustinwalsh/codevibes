#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN"
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"JWT_SECRET":"j","ENCRYPTION_KEY":"0123456789abcdef0123456789abcdef","GITHUB_CLIENT_ID":"id","GITHUB_CLIENT_SECRET":"sec","TUNNEL_CRED":"{\"TunnelID\":\"x\"}"}'
EOF
  cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$TMP_LOG"; exit 0
EOF
  chmod +x "$BIN/curl" "$BIN/podman"
  export PATH="$BIN:$PATH" TMP_LOG="$TMP/calls.log"
  export CF_SERVICE_TOKEN_ID=tid CF_SERVICE_TOKEN_SECRET=tsec
}
teardown() { rm -rf "$TMP"; }

@test "creates a podman secret per app secret" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -eq 0 ]
  grep -q "secret create codevibes-jwt-secret" "$TMP/calls.log"
  grep -q "secret create codevibes-encryption-key" "$TMP/calls.log"
  grep -q "secret create codevibes-tunnel-cred" "$TMP/calls.log"
}
@test "does NOT log into ghcr (images are public, anonymous pull)" {
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  ! grep -q "login ghcr.io" "$TMP/calls.log"
}
@test "fails if the service token is missing (no silent unauth fetch)" {
  unset CF_SERVICE_TOKEN_ID
  run bash "$BATS_TEST_DIRNAME/../fetch-secrets.sh"
  [ "$status" -ne 0 ]
}
