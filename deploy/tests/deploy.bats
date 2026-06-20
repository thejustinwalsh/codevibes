#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/state"
  # mock curl: ghcr token endpoint + tags/list endpoint (report a newer tag)
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  *ghcr.io/token*) echo '{"token":"t"}'; exit 0 ;;
  *tags/list*) echo '{"tags":["v1.0.1","v1.0.2"]}'; exit 0 ;;
esac; done
exit 0
EOF
  # mock jq: minimal — extract .token and .tags[]?
  cat > "$BIN/jq" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"
case "$*" in
  *.token*) echo "t" ;;
  *.tags*) echo "v1.0.1"; echo "v1.0.2" ;;
esac
EOF
  # mock podman: log calls; succeed
  cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$TMP_LOG"
case "$1" in
  tag) echo "tag $*" >> "$TMP_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BIN/curl" "$BIN/jq" "$BIN/podman"
  export PATH="$BIN:$PATH" TMP_LOG="$TMP/calls.log"
  export DEPLOY_STATE_DIR="$TMP/state" DEPLOY_SMOKE_OVERRIDE=pass
}
teardown() { rm -rf "$TMP"; }

@test "deploys newer tag and records last-known-good" {
  run bash "$BATS_TEST_DIRNAME/../deploy.sh"
  [ "$status" -eq 0 ]
  grep -q "tag .*codevibes-backend:v1.0.2 localhost/codevibes-backend:current" "$TMP/calls.log"
  grep -q "v1.0.2" "$TMP/state/deploy-state"
}

@test "rollback retargets current to the previous good tag" {
  printf 'CURRENT=v1.0.2\nPREVIOUS=v1.0.1\n' > "$TMP/state/deploy-state"
  run bash "$BATS_TEST_DIRNAME/../deploy.sh" --rollback
  [ "$status" -eq 0 ]
  grep -q "codevibes-backend:v1.0.1 localhost/codevibes-backend:current" "$TMP/calls.log"
}

@test "failed smoke test does NOT swap current (no data-loss / no bad deploy)" {
  export DEPLOY_SMOKE_OVERRIDE=fail
  run bash "$BATS_TEST_DIRNAME/../deploy.sh"
  [ "$status" -ne 0 ]
  ! grep -q ":v1.0.2 localhost/codevibes-backend:current" "$TMP/calls.log"
}
