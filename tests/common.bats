#!/usr/bin/env bats
# common.sh behavior, exercised through hook-curl.sh (its thinnest consumer).
# Setup/config errors keep the behavior of the originally released plugin:
# a clear stderr message and exit 1. (Silent degradation applies only to the
# inventory feature's fallback paths — see hook-mcp-inventory.bats.)

load test_helper

@test "rejects NOMA_API_URL outside noma.security" {
  export NOMA_API_URL="https://api.evil.com"
  run_hook hook-curl.sh '{"a":1}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"must point to a *.noma.security host"* ]]
}

@test "rejects lookalike domain evilnoma.security" {
  export NOMA_API_URL="https://evilnoma.security"
  run_hook hook-curl.sh '{"a":1}'
  [ "$status" -eq 1 ]
}

@test "accepts bare noma.security and subdomains" {
  export NOMA_API_URL="https://noma.security"
  run_hook hook-curl.sh '{"a":1}'
  [ "$status" -eq 0 ]
  [ "$(payload_field '.a')" = "1" ]

  export NOMA_API_URL="https://api.eu.noma.security:8443/base"
  run_hook hook-curl.sh '{"a":1}'
  [ "$status" -eq 0 ]
  [ "$(payload_field '.a')" = "1" ]
}

@test "exits with a clear message when NOMA_API_KEY cannot be resolved" {
  unset NOMA_API_KEY
  # PATH without security / secret-tool: no keychain fallback available
  run_hook_sandboxed hook-curl.sh '{"a":1}' cat sed dirname hostname whoami
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOMA_API_KEY not found"* ]]
}

@test "failed POST reports a [Noma] error and exits non-zero" {
  unset NOMA_DRYRUN
  local sandbox tool tool_path
  sandbox="$(mktemp -d -p "$TEST_HOME")"
  for tool in cat sed dirname hostname whoami; do
    tool_path="$(command -v "$tool")" && ln -s "$tool_path" "$sandbox/$tool"
  done
  # a curl that always fails, standing in for network/auth errors
  printf '#!/bin/sh\nexit 7\n' > "$sandbox/curl"
  chmod +x "$sandbox/curl"
  run bash -c 'printf "%s" "$1" | HOME="$2" PATH="$3" "$4" "$5"' _ \
    '{"a":1}' "$TEST_HOME" "$sandbox" "$TEST_SHELL_BIN" "$SCRIPTS_DIR/hook-curl.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[Noma]"* ]]
}

@test "dry run prints the payload and never needs curl" {
  # PATH without curl proves NOMA_DRYRUN short-circuits before any network call
  run_hook_sandboxed hook-curl.sh '{"a":1}' cat sed dirname hostname whoami
  [ "$status" -eq 0 ]
  [ "$(payload_field '.a')" = "1" ]
}

@test "payload is enriched with non-empty hostname and username" {
  run_hook hook-curl.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
  [ "$status" -eq 0 ]
  [ "$(payload_field '.hostname | length > 0')" = "true" ]
  [ "$(payload_field '.username | length > 0')" = "true" ]
}
