#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/src/hooks" "$TMP/codevibes-backend/src"
  cp "$BATS_TEST_DIRNAME/fixtures/useAnalysis.ts" "$TMP/src/hooks/useAnalysis.ts"
  cp "$BATS_TEST_DIRNAME/fixtures/server.ts" "$TMP/codevibes-backend/src/server.ts"
}
teardown() { rm -rf "$TMP"; }

@test "rewrites the hardcoded API base to env-relative" {
  run bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  [ "$status" -eq 0 ]
  grep -q "import.meta.env.VITE_API_URL || ''" "$TMP/src/hooks/useAnalysis.ts"
  ! grep -q "'http://localhost:3001'" "$TMP/src/hooks/useAnalysis.ts"
}

@test "tightens the permissive CORS fallback" {
  run bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  [ "$status" -eq 0 ]
  grep -q "Not allowed by CORS" "$TMP/codevibes-backend/src/server.ts"
  ! grep -q "callback(null, true); // Allow for development" "$TMP/codevibes-backend/src/server.ts"
}

@test "fails loudly if a target literal is missing (upstream changed)" {
  echo "const API_BASE_URL = 'changed';" > "$TMP/src/hooks/useAnalysis.ts"
  run bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 1"* ]]
}

@test "is idempotent (second run is a no-op success)" {
  bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  run bash "$BATS_TEST_DIRNAME/../apply.sh" "$TMP"
  [ "$status" -eq 0 ]
}
