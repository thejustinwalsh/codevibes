#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/state"
  # mock skopeo: report a newer tag
  cat > "$BIN/skopeo" <<'EOF'
#!/usr/bin/env bash
echo '{"Tags":["v1.0.1","v1.0.2"]}'
EOF
  # mock podman: log calls; succeed; health/db smoke "passes" via marker file
  cat > "$BIN/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$TMP_LOG"
case "$1" in
  run) exit 0 ;;
  tag) echo "tag $*" >> "$TMP_LOG"; exit 0 ;;
  pull) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BIN/skopeo" "$BIN/podman"
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
