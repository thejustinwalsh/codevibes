#!/usr/bin/env bats

@test "make help lists verify and test targets" {
  run make -C "${BATS_TEST_DIRNAME}/../.." help
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify-shell"* ]]
  [[ "$output" == *"verify-yaml"* ]]
  [[ "$output" == *"verify-docker"* ]]
  [[ "$output" == *"verify-actions"* ]]
  [[ "$output" == *"test"* ]]
}

@test "config.env defines the canonical image names" {
  run bash -c "set -a; source ${BATS_TEST_DIRNAME}/../config.env; echo \$IMAGE_BACKEND \$IMAGE_WEB \$POD_NAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codevibes-backend"* ]]
  [[ "$output" == *"codevibes-web"* ]]
  [[ "$output" == *"codevibes"* ]]
}
