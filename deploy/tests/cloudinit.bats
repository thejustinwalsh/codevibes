#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"
  cat > "$TMP/vars" <<'EOF'
CF_SERVICE_TOKEN_ID=tid
CF_SERVICE_TOKEN_SECRET=tsec
FORK_REPO=thejustinwalsh/codevibes
TUNNEL_ID=abc-123
EOF
}
teardown() { rm -rf "$TMP"; }

@test "renders, substitutes vars, and stays under 32 KiB" {
  run bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$TMP/out.yaml")" -lt 32768 ]
  ! grep -q "__" "$TMP/out.yaml"        # no leftover placeholders
  grep -q "tid" "$TMP/out.yaml"
}
@test "output is valid cloud-init/YAML" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  run yamllint -d relaxed "$TMP/out.yaml"
  [ "$status" -eq 0 ]
}
@test "enables linger, mounts the volume, and never reformats existing data" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  grep -q "enable-linger" "$TMP/out.yaml"
  grep -q "mkfs.ext4" "$TMP/out.yaml"
  grep -q "blkid" "$TMP/out.yaml"       # only format if no existing FS
}
