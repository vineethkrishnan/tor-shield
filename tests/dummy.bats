#!/usr/bin/env bats

@test "math works" {
  result="$(( 2 + 2 ))"
  [ "$result" -eq 4 ]
}

@test "setup script exists and is executable" {
  # We test that the main setup script exists in the parent directory
  [ -f "${BATS_TEST_DIRNAME}/../setup.sh" ]
  [ -x "${BATS_TEST_DIRNAME}/../setup.sh" ]
}
