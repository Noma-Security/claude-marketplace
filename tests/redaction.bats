#!/usr/bin/env bats
# Exhaustive coverage of the secret-redaction logic in hook-mcp-inventory.sh:
# the sanitize_str pattern chain, the argv-aware sanitize_args masking, and the
# fields they apply to (url / command / args) across every artifact source.
#
# Direction of safety: over-redaction is acceptable, leaking is not. Tests that
# pin a known false positive say so explicitly.

load test_helper

# probe_args <json-array> — run the hook against a project .mcp.json whose
# single server has the given args
probe_args() {
  require_osascript
  write_project_mcp_json "$(jq -nc --argjson a "$1" '{mcpServers: {probe: {type: "stdio", command: "npx", args: $a}}}')"
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
}

# probe_arg <index> — the sanitized arg at that position
probe_arg() {
  artifact_field project claude_mcp_json ".content.mcpServers.probe.args[$1]"
}

# --- token-prefix patterns ----------------------------------------------------

@test "masks the full GitHub/GitLab token family" {
  probe_args '["github_pat_11AAAAA0secret", "ghp_abcdefgh12345678901234", "gho_abcdefgh12345678901234", "ghu_abcdefgh12345678901234", "ghs_abcdefgh12345678901234", "ghr_abcdefgh12345678901234", "glpat-abcdefgh123456"]'
  for i in 0 1 2 3 4 5 6; do
    [ "$(probe_arg $i)" = "***REDACTED***" ]
  done
}

@test "masks sk- keys of 8+ chars but keeps short and word-embedded lookalikes" {
  probe_args '["sk-abcdefgh", "sk-proj-longersecretvalue", "sk-dev", "task-12345678"]'
  [ "$(probe_arg 0)" = "***REDACTED***" ]
  [ "$(probe_arg 1)" = "***REDACTED***" ]
  [ "$(probe_arg 2)" = "sk-dev" ]
  [ "$(probe_arg 3)" = "task-12345678" ]
}

@test "masks Slack xox[baprs] tokens and keeps unknown xox variants" {
  probe_args '["xoxb-1234-5678-abcdef", "xoxp-1111-2222-cccc", "xoxz-not-a-real-prefix"]'
  [ "$(probe_arg 0)" = "***REDACTED***" ]
  [ "$(probe_arg 1)" = "***REDACTED***" ]
  [ "$(probe_arg 2)" = "xoxz-not-a-real-prefix" ]
}

@test "masks AWS access key ids only at their exact shape" {
  probe_args '["AKIAIOSFODNN7EXAMPLE", "AKIA123", "akiaiosfodnn7example"]'
  [ "$(probe_arg 0)" = "***REDACTED***" ]
  [ "$(probe_arg 1)" = "AKIA123" ]
  [ "$(probe_arg 2)" = "akiaiosfodnn7example" ]
}

@test "masks JWTs but keeps short eyJ fragments" {
  probe_args '["eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig-part", "eyJa.b.c"]'
  [ "$(probe_arg 0)" = "***REDACTED***" ]
  [ "$(probe_arg 1)" = "eyJa.b.c" ]
}

@test "masks Bearer tokens case-insensitively, keeps a bare Bearer word" {
  probe_args '["Bearer abc123token", "bearer lowertoken123", "BEARER YELLING99", "Bearer"]'
  [ "$(probe_arg 0)" = "Bearer ***REDACTED***" ]
  # masking normalizes the keyword casing — value is gone either way
  [ "$(probe_arg 1)" = "Bearer ***REDACTED***" ]
  [ "$(probe_arg 2)" = "Bearer ***REDACTED***" ]
  [ "$(probe_arg 3)" = "Bearer" ]
  refute_payload_contains "lowertoken123"
  refute_payload_contains "YELLING99"
}

# --- KEY=VALUE pattern --------------------------------------------------------

@test "masks KEY=VALUE for secret-ish keys, preserving the key name" {
  probe_args '["MY_API_TOKEN=abc123", "password=hunter2", "ACCESS_KEY=AKIA-ish", "db-credential-prod=s3cret", "GITHUB_AUTH=xyz"]'
  [ "$(probe_arg 0)" = "MY_API_TOKEN=***REDACTED***" ]
  [ "$(probe_arg 1)" = "password=***REDACTED***" ]
  [ "$(probe_arg 2)" = "ACCESS_KEY=***REDACTED***" ]
  [ "$(probe_arg 3)" = "db-credential-prod=***REDACTED***" ]
  [ "$(probe_arg 4)" = "GITHUB_AUTH=***REDACTED***" ]
  refute_payload_contains "hunter2"
}

@test "keeps KEY=VALUE for non-secret keys" {
  probe_args '["NODE_ENV=production", "LOG_LEVEL=debug", "WORKERS=4"]'
  [ "$(probe_arg 0)" = "NODE_ENV=production" ]
  [ "$(probe_arg 1)" = "LOG_LEVEL=debug" ]
  [ "$(probe_arg 2)" = "WORKERS=4" ]
}

# --- argv-aware flag masking ---------------------------------------------------

@test "masks the value following every secret-ish flag spelling" {
  probe_args '["--token", "v1", "--api-key", "v2", "--apikey", "v3", "--access-key", "v4", "--auth", "v5", "--pat", "v6", "--client-secret", "v7", "-password", "v8"]'
  for i in 1 3 5 7 9 11 13 15; do
    [ "$(probe_arg $i)" = "***REDACTED***" ]
  done
  refute_payload_contains '"v1"'
  refute_payload_contains '"v8"'
}

@test "keeps values following non-secret flags" {
  probe_args '["--port", "8080", "-o", "out.json", "--verbose", "true"]'
  [ "$(probe_arg 1)" = "8080" ]
  [ "$(probe_arg 3)" = "out.json" ]
  [ "$(probe_arg 5)" = "true" ]
}

@test "masks inline --flag=value through the KEY=VALUE rule" {
  probe_args '["--api-key=inline-secret-1", "--token=inline-secret-2"]'
  [ "$(probe_arg 0)" = "--api-key=***REDACTED***" ]
  [ "$(probe_arg 1)" = "--token=***REDACTED***" ]
}

@test "masks non-string values following a secret flag and stringifies other non-strings" {
  probe_args '["--token", 12345, "-p", 8080, true]'
  [ "$(probe_arg 1)" = "***REDACTED***" ]
  [ "$(probe_arg 3)" = "8080" ]
  [ "$(probe_arg 4)" = "true" ]
}

@test "over-redacts values after flags merely containing a keyword (safe direction)" {
  # --author contains "auth": its value is masked. A false positive we accept —
  # the failure mode is a lost author name, never a leaked secret.
  probe_args '["--author", "Jane Doe"]'
  [ "$(probe_arg 0)" = "--author" ]
  [ "$(probe_arg 1)" = "***REDACTED***" ]
}

# --- URLs ----------------------------------------------------------------------

@test "masks URL userinfo keeping the scheme, in url field and args alike" {
  require_osascript
  write_project_mcp_json '{"mcpServers":{"probe":{
    "type": "http",
    "url": "https://admin:letmein99@mcp.example/path",
    "args": ["postgres://svc:dbpass42@db.internal:5432/app"]
  }}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field project claude_mcp_json '.content.mcpServers.probe.url')" = "https://***REDACTED***@mcp.example/path" ]
  [ "$(artifact_field project claude_mcp_json '.content.mcpServers.probe.args[0]')" = "postgres://***REDACTED***@db.internal:5432/app" ]
  refute_payload_contains "letmein99"
  refute_payload_contains "dbpass42"
}

@test "keeps ssh-style remotes without password userinfo" {
  probe_args '["git@github.com:org/repo.git"]'
  [ "$(probe_arg 0)" = "git@github.com:org/repo.git" ]
}

@test "masks secret query parameters inside URLs" {
  probe_args '["https://x.example/mcp?api_key=abc123&page=2"]'
  [[ "$(probe_arg 0)" == "https://x.example/mcp?api_key=***REDACTED***"* ]]
  refute_payload_contains "abc123"
}

# --- field coverage --------------------------------------------------------------

@test "sanitizes the command field, passes type through untouched" {
  require_osascript
  write_project_mcp_json '{"mcpServers":{"probe":{
    "type": "stdio",
    "command": "API_TOKEN=cmdsecret77 ./start.sh"
  }}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field project claude_mcp_json '.content.mcpServers.probe.command')" = "API_TOKEN=***REDACTED*** ./start.sh" ]
  [ "$(artifact_field project claude_mcp_json '.content.mcpServers.probe.type')" = "stdio" ]
  refute_payload_contains "cmdsecret77"
}

@test "masks multiple secrets inside a single string" {
  probe_args '["run with Bearer tok111 and ghp_tok2222222222222222 and PASSWORD=tok333"]'
  [ "$(probe_arg 0)" = "run with Bearer ***REDACTED*** and ***REDACTED*** and PASSWORD=***REDACTED***" ]
}

@test "leaves entirely clean configs byte-identical" {
  probe_args '["-y", "@scope/server-name", "--port", "8080", "https://plain.example/mcp"]'
  [ "$(artifact_field project claude_mcp_json '.content.mcpServers.probe.args | join(" ")')" = "-y @scope/server-name --port 8080 https://plain.example/mcp" ]
}

@test "applies redaction in every artifact source, not just the project file" {
  require_osascript
  write_home_claude_json "$(jq -nc --arg p "$TEST_PROJECT" '{
    mcpServers: {u: {type: "stdio", command: "npx", args: ["--token", "user-scope-leak"]}},
    projects: {($p): {mcpServers: {l: {type: "http", url: "https://a:local-scope-leak@h.example"}}}}
  }')"
  write_user_mcp_json '{"servers":{"m":{"type":"stdio","command":"npx","args":["ghp_mcpjson00000000000000leak"]}}}'
  add_plugin leaky .mcp.json '{"mcpServers":{"p":{"type":"stdio","command":"npx","args":["MY_SECRET=plugin-scope-leak"]}}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_count)" = "4" ]
  refute_payload_contains "user-scope-leak"
  refute_payload_contains "local-scope-leak"
  refute_payload_contains "ghp_mcpjson"
  refute_payload_contains "plugin-scope-leak"
}
