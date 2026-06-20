#!/usr/bin/env bats
Q="${BATS_TEST_DIRNAME}/../quadlet"

@test "pod defines no published host ports (tunnel dials out)" {
  ! grep -Rq "PublishPort" "$Q"
}
@test "containers reference floating :current images" {
  grep -q "Image=localhost/codevibes-backend:current" "$Q/codevibes-backend.container"
  grep -q "Image=localhost/codevibes-web:current" "$Q/codevibes-web.container"
}
@test "backend maps podman secrets to env targets" {
  grep -q "Secret=codevibes-jwt-secret,type=env,target=JWT_SECRET" "$Q/codevibes-backend.container"
  grep -q "Secret=codevibes-encryption-key,type=env,target=ENCRYPTION_KEY" "$Q/codevibes-backend.container"
}
@test "data volume binds the host mount" {
  grep -q "Device=/mnt/codevibes-data" "$Q/codevibes-data.volume"
}
@test "quadlet dry-run accepts the unit set" {
  QUADLET=$(command -v quadlet || echo /usr/libexec/podman/quadlet)
  [ -x "$QUADLET" ] || skip "quadlet not installed (Linux/OrbStack only)"
  run env QUADLET_UNIT_DIRS="$Q" "$QUADLET" -dryrun -user
  [ "$status" -eq 0 ]
}
@test "cloudflared config template has app ingress + 404 fallback" {
  T="${BATS_TEST_DIRNAME}/../cloudflared/config.yml.template"
  grep -q "hostname: codevibes.tjw.dev" "$T"
  grep -q "http_status:404" "$T"
}
