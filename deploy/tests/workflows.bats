#!/usr/bin/env bats
WF="${BATS_TEST_DIRNAME}/../../.github/workflows"

@test "workflows pass actionlint" {
  run actionlint
  [ "$status" -eq 0 ]
}
@test "sync runs daily and only acts on new tags" {
  grep -q "cron:" "$WF/sync.yml"
  grep -q "danish296/codevibes" "$WF/sync.yml"
}
@test "build runs the codemod before building, on release" {
  grep -q "release:" "$WF/build.yml"
  grep -q "patches/apply.sh" "$WF/build.yml"
  grep -q "codevibes-backend" "$WF/build.yml"
  grep -q "codevibes-web" "$WF/build.yml"
}
