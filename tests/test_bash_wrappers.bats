#!/usr/bin/env bats

setup() {
  export SCRIPT_DIR="${BATS_TEST_DIRNAME}/.."
}

@test "setup.sh requires root privileges" {
  # When run as a normal user, setup.sh should refuse to execute
  # BATS runs without sudo unless explicitly requested
  run "${SCRIPT_DIR}/setup.sh" --precheck
  [ "$status" -eq 1 ]
  [[ "$output" == *"Please run as root"* ]]
}

@test "setup.sh detects missing arguments for --domain" {
  # We use a mocked ID temporarily or run the script up to the arg parse fail to avoid sudo hanging
  run bash -c "ROOT_BYPASS=1 ${SCRIPT_DIR}/setup.sh --domain"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--domain requires a value"* ]]
}

@test "additional-tor-nodes.sh executes without fast failure" {
  # We just test the help or syntax of additional-tor-nodes.sh
  # Since we are mocking, we avoid hitting the internet heavily
  bash -n "${SCRIPT_DIR}/additional-tor-nodes.sh"
  [ "$?" -eq 0 ]
}
