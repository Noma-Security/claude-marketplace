#!/usr/bin/env bats
# hook-curl.sh — serves PreToolUse / PostToolUse

load test_helper

@test "forwards the event byte-identical apart from hostname/username" {
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"s1","cwd":"/tmp"}'
  run_hook hook-curl.sh "$event"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -cS 'del(.hostname, .username)')" = "$(printf '%s' "$event" | jq -cS '.')" ]
}

@test "handles PostToolUse events with nested tool_response" {
  local event='{"hook_event_name":"PostToolUse","tool_name":"mcp__github__get_me","tool_input":{},"tool_response":{"items":[1,2,3]},"session_id":"s2"}'
  run_hook hook-curl.sh "$event"
  [ "$status" -eq 0 ]
  [ "$(payload_field '.tool_response.items | length')" = "3" ]
  [ "$(payload_field '.tool_name')" = "mcp__github__get_me" ]
}
