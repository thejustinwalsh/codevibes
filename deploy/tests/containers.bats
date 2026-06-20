#!/usr/bin/env bats
ROOT="${BATS_TEST_DIRNAME}/../.."

@test "backend Dockerfile installs native build deps in builder" {
  grep -Eq "python3.*make.*g\+\+|g\+\+.*make.*python3" "$ROOT/codevibes-backend/Dockerfile"
}
@test "backend final stage has no build toolchain (copies node_modules)" {
  grep -q "COPY --from=builder /app/node_modules" "$ROOT/codevibes-backend/Dockerfile"
}
@test "backend Dockerfile passes hadolint (no errors)" {
  run hadolint --failure-threshold error "$ROOT/codevibes-backend/Dockerfile"
  [ "$status" -eq 0 ]
}
@test "web Dockerfile builds with VITE_API_URL and serves via caddy" {
  grep -q "VITE_API_URL" "$ROOT/Dockerfile.web"
  grep -Eq "FROM caddy" "$ROOT/Dockerfile.web"
  run hadolint --failure-threshold error "$ROOT/Dockerfile.web"
  [ "$status" -eq 0 ]
}
@test "Caddyfile is valid and proxies /api to backend" {
  grep -q "reverse_proxy localhost:3001" "$ROOT/Caddyfile"
  run caddy validate --config "$ROOT/Caddyfile" --adapter caddyfile
  [ "$status" -eq 0 ]
}
