#!/usr/bin/env bats
# hook-mcp-inventory.sh — per-file MCP artifact collection on UserPromptSubmit.
# The inventory is built by inventory_claude_code.py (any python3), so these
# tests skip where python3 is absent; the fallback test runs everywhere.

load test_helper

# --- sources ----------------------------------------------------------------

@test "reports user servers from ~/.claude.json mcpServers" {
  require_python3
  write_home_claude_json '{"mcpServers":{"alpha":{"type":"http","url":"https://alpha.example"}},"numStartups":42}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field user claude_json '.content.mcpServers.alpha.url')" = "https://alpha.example" ]
  [ "$(artifact_field user claude_json '.path')" = "$TEST_HOME/.claude.json" ]
}

@test "reports user servers from the ~/.claude.json servers variant" {
  require_python3
  write_home_claude_json '{"servers":{"beta":{"type":"http","url":"https://beta.example"}}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field user claude_json '.content.mcpServers.beta.url')" = "https://beta.example" ]
}

@test "never applies the bare-map heuristic to ~/.claude.json top level" {
  require_python3
  # an unrelated top-level object that merely looks like a server config
  write_home_claude_json '{"cachedDynamicConfigs":{"type":"remote","url":"https://internal.example"}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_count user claude_json)" = "0" ]
  refute_payload_contains "internal.example"
}

@test "reports local scope from the projects entry with only its server map" {
  require_python3
  write_home_claude_json "$(jq -nc --arg p "$TEST_PROJECT" '{projects: {($p): {
    mcpServers: {gh: {type: "stdio", command: "docker", args: ["run", "-i"]}},
    enabledMcpjsonServers: ["gh"],
    lastSessionFirstPrompt: "SUPER PRIVATE PROMPT",
    allowedTools: ["Bash(rm:*)"]
  }}}')"
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field local claude_json '.content.mcpServers.gh.command')" = "docker" ]
  # only the server map is extracted — no enable/disable lists, nothing else
  [ "$(artifact_field local claude_json '.content | keys | join(",")')" = "mcpServers" ]
  refute_payload_contains "SUPER PRIVATE PROMPT"
  refute_payload_contains "allowedTools"
  refute_payload_contains "enabledMcpjsonServers"
}

@test "reports the standalone ~/.claude/mcp.json (servers key, normalized)" {
  require_python3
  write_user_mcp_json '{"servers":{"logger":{"type":"http","url":"https://logger.example"}}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field user claude_mcp_json '.content.mcpServers.logger.url')" = "https://logger.example" ]
  [ "$(artifact_field user claude_mcp_json '.path')" = "$TEST_HOME/.claude/mcp.json" ]
}

@test "reports the project .mcp.json" {
  require_python3
  write_project_mcp_json '{"mcpServers":{"proj":{"type":"stdio","command":"npx","args":["-y","proj-server"]}}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field project claude_mcp_json '.content.mcpServers.proj.command')" = "npx" ]
  [ "$(artifact_field project claude_mcp_json '.path')" = "$TEST_PROJECT/.mcp.json" ]
}

@test "reports plugin .mcp.json in both wrapped and bare shapes" {
  require_python3
  add_plugin wrapped .mcp.json '{"mcpServers":{"w":{"type":"http","url":"https://w.example"}}}'
  add_plugin bare .mcp.json '{"b":{"type":"http","url":"https://b.example"}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_count plugin claude_mcp_json)" = "2" ]
  [ "$(payload_field '[.mcp_artifacts[] | select(.scope=="plugin") | .content.mcpServers | keys[]] | sort | join(",")')" = "b,w" ]
}

@test "sends the full plugin.json manifest verbatim as claude_plugin_json" {
  require_python3
  add_plugin metadata-only .claude-plugin/plugin.json '{"name":"metadata-only","version":"1.2.3","description":"d","author":{"name":"a"},"repository":"https://r.example"}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  # whole manifest is sent, fields verbatim
  [ "$(artifact_field plugin claude_plugin_json '.content | {name,version,description,repository} | join("|")')" = "metadata-only|1.2.3|d|https://r.example" ]
  [ "$(artifact_field plugin claude_plugin_json '.content.author.name')" = "a" ]
  # a manifest without servers produces no .mcp.json artifact
  [ "$(artifact_count plugin claude_mcp_json)" = "0" ]
}

@test "captures inline mcpServers in the manifest and cleans their secrets" {
  require_python3
  add_plugin inline .claude-plugin/plugin.json '{"name":"inline","version":"1.0.0","mcpServers":{"srv":{"type":"stdio","command":"npx","args":["-y","s","--token","supersecret9"],"env":{"API_KEY":"github_pat_11AAAAA0leak"},"headers":{"Authorization":"Bearer sk-deadbeef00000000"}}}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  # inline servers ride in the manifest artifact, allowlisted + masked
  [ "$(artifact_field plugin claude_plugin_json '.content.mcpServers.srv | keys | sort | join(",")')" = "args,command,type" ]
  [ "$(artifact_field plugin claude_plugin_json '.content.mcpServers.srv.args[3]')" = "***REDACTED***" ]
  [ "$(artifact_field plugin claude_plugin_json '.content.name')" = "inline" ]
  refute_payload_contains '"env"'
  refute_payload_contains '"headers"'
  refute_payload_contains "supersecret9"
  refute_payload_contains "github_pat_"
}

@test "emits both manifest and .mcp.json artifacts when both exist" {
  require_python3
  # mirrors the Notion plugin: servers in .mcp.json, name (capitalized, != server
  # key) in the manifest — ai-dr needs the name to parse mcp__plugin_* tools
  add_plugin notion .mcp.json '{"mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.com/mcp"}}}'
  add_plugin notion .claude-plugin/plugin.json '{"name":"Notion","version":"0.1.0"}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_count plugin claude_plugin_json)" = "1" ]
  [ "$(artifact_count plugin claude_mcp_json)" = "1" ]
  [ "$(artifact_field plugin claude_plugin_json '.content.name')" = "Notion" ]
  [ "$(artifact_field plugin claude_mcp_json '.content.mcpServers.notion.url')" = "https://mcp.notion.com/mcp" ]
  [ "$(artifact_field plugin claude_mcp_json '.content.pluginName')" = "Notion" ]
}

@test "excludes local-scoped plugins installed for a different project" {
  require_python3
  add_plugin other-project .mcp.json '{"mcpServers":{"other":{"type":"http","url":"https://other.example"}}}' local /somewhere/else
  add_plugin this-project .mcp.json '{"mcpServers":{"mine":{"type":"http","url":"https://mine.example"}}}' local "$TEST_PROJECT"
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_count plugin claude_mcp_json)" = "1" ]
  refute_payload_contains "other.example"
}

@test "reports managed-mcp.json when present (requires sudo, auto-skips)" {
  require_python3
  if [ -e /etc/claude-code/managed-mcp.json ]; then
    skip "real managed-mcp.json present on this machine"
  fi
  if [ -e "/Library/Application Support/ClaudeCode/managed-mcp.json" ]; then
    skip "real managed config present on this machine"
  fi
  if ! sudo -n true 2>/dev/null; then
    skip "needs passwordless sudo for /etc/claude-code (runs in CI)"
  fi
  sudo mkdir -p /etc/claude-code
  printf '%s' '{"mcpServers":{"corp":{"type":"http","url":"https://mcp.corp.example"}}}' | sudo tee /etc/claude-code/managed-mcp.json > /dev/null
  MANAGED_MCP_CREATED=1

  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field managed claude_managed_mcp_json '.content.mcpServers.corp.url')" = "https://mcp.corp.example" ]
}

# --- settings files ---------------------------------------------------------

@test "ordinary settings.json / settings.local.json are never read, even with an mcpServers block" {
  require_python3
  # only remote-settings.json / managed-settings.json feed the inventory; the
  # ordinary user/project settings files stay unread — mcpServers block included.
  write_settings "$TEST_HOME/.claude/settings.json" '{"disabledMcpjsonServers":["dropped"],"mcpServers":{"x":{"url":"https://nope.example"}},"env":{"FOO":"bar"}}'
  write_settings "$TEST_PROJECT/.claude/settings.json" '{"enabledMcpjsonServers":["kept"]}'
  write_settings "$TEST_PROJECT/.claude/settings.local.json" '{"disabledMcpjsonServers":["x"]}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_count '' claude_settings_json)" = "0" ]
  refute_payload_contains "claude_settings_json"
  refute_payload_contains "disabledMcpjsonServers"
  refute_payload_contains "nope.example"
  refute_payload_contains '"FOO"'
}

@test "reports remote-settings.json servers, taking the mcpServers block only" {
  require_python3
  write_settings "$TEST_HOME/.claude/remote-settings.json" '{"mcpServers":{"corp":{"type":"http","url":"https://remote.example","headers":{"Authorization":"Bearer sk-deadbeef00000000"}}},"env":{"DD_API_KEY":"cafebabecafebabecafebabecafebabe"}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field remote claude_settings_json '.content.mcpServers.corp.url')" = "https://remote.example" ]
  [ "$(artifact_field remote claude_settings_json '.path')" = "$TEST_HOME/.claude/remote-settings.json" ]
  refute_payload_contains "DD_API_KEY"
  refute_payload_contains '"env"'
  refute_payload_contains '"headers"'
  refute_payload_contains "sk-deadbeef"
}

@test "remote-settings.json without an mcpServers block yields no artifact" {
  require_python3
  write_settings "$TEST_HOME/.claude/remote-settings.json" '{"env":{"DD_API_KEY":"secret123"},"permissions":{"defaultMode":"auto"}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_count remote claude_settings_json)" = "0" ]
  refute_payload_contains "DD_API_KEY"
}

# --- privacy / masking ------------------------------------------------------

@test "drops env and headers entirely, allowlisting only identity fields" {
  require_python3
  write_project_mcp_json '{"mcpServers":{"gh":{
    "type": "stdio", "command": "docker", "args": ["run"],
    "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "github_pat_11AAAAA0secretsecret"},
    "headers": {"Authorization": "Bearer sk-deadbeefdeadbeef"},
    "_meta": {"internal": true}
  }}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field project claude_mcp_json '.content.mcpServers.gh | keys | sort | join(",")')" = "args,command,type" ]
  refute_payload_contains '"env"'
  refute_payload_contains '"headers"'
  refute_payload_contains "github_pat_"
  refute_payload_contains "sk-deadbeef"
  refute_payload_contains "_meta"
}

@test "masks secret-looking values inside url, command and args" {
  require_python3
  write_project_mcp_json '{"mcpServers":{"evil":{
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "some-server", "--api-key", "supersecret123", "API_TOKEN=abc123def", "https://user:hunter2@x.example/p"],
    "url": "https://admin:letmein99@evil.example/mcp"
  }}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(artifact_field project claude_mcp_json '.content.mcpServers.evil.args[3]')" = "***REDACTED***" ]
  refute_payload_contains "supersecret123"
  refute_payload_contains "hunter2"
  refute_payload_contains "abc123def"
  refute_payload_contains "letmein99"
}

# --- payload shape & fallbacks ----------------------------------------------

@test "preserves the original event and appends artifacts plus host identity" {
  require_python3
  write_home_claude_json '{"mcpServers":{"alpha":{"type":"http","url":"https://alpha.example"}}}'
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(payload_field '.prompt')" = "hi" ]
  [ "$(payload_field '.session_id')" = "test-session" ]
  [ "$(payload_field '.hook_event_name')" = "UserPromptSubmit" ]
  [ "$(payload_field '.hostname | length > 0')" = "true" ]
  [ "$(payload_field '.username | length > 0')" = "true" ]
  [ "$(payload_field '.mcp_artifacts | type')" = "array" ]
}

@test "empty sandbox yields an empty artifact list without crashing" {
  require_python3
  run_hook hook-mcp-inventory.sh "$(default_event)"
  [ "$status" -eq 0 ]
  [ "$(payload_field '.mcp_artifacts')" = "[]" ]
  [ "$(payload_field '.prompt')" = "hi" ]
}

@test "malformed stdin degrades to a fallback envelope" {
  require_python3
  run_hook hook-mcp-inventory.sh 'this is not json {'
  [ "$status" -eq 0 ]
  [ "$(payload_field '.hook_event_name')" = "UserPromptSubmit" ]
  [ "$(payload_field '.cwd | length > 0')" = "true" ]
  [ "$(payload_field '.mcp_artifacts | type')" = "array" ]
}

@test "inventory needs nothing beyond python3 and the base utilities" {
  require_python3
  # PATH sandbox with python3 but deliberately no jq: full inventory expected
  write_home_claude_json '{"mcpServers":{"alpha":{"type":"http","url":"https://alpha.example"}}}'
  run_hook_sandboxed hook-mcp-inventory.sh "$(default_event)" cat sed dirname hostname whoami uname python3
  [ "$status" -eq 0 ]
  [ "$(artifact_field user claude_json '.content.mcpServers.alpha.url')" = "https://alpha.example" ]
}

@test "python3 failure (missing inventory_claude_code.py) falls back silently too" {
  require_python3
  local dir
  dir="$(mktemp -d -p "$TEST_HOME")"
  mkdir -p "$dir/common"
  cp "$SCRIPTS_DIR/hook-mcp-inventory.sh" "$dir/"
  cp "$SCRIPTS_DIR/common/common.sh" "$dir/common/"
  # deliberately omit inventory_claude_code.py: python3 cannot build the inventory
  run bash -c 'printf "%s" "$1" | HOME="$2" "$3" "$4"' _ \
    "$(default_event)" "$TEST_HOME" "$TEST_SHELL_BIN" "$dir/hook-mcp-inventory.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.' > /dev/null
  [[ "$output" != *"[Noma]"* ]]
  [ "$(printf '%s' "$output" | jq -r '.prompt')" = "hi" ]
  [ "$(printf '%s' "$output" | jq -r 'has("mcp_artifacts")')" = "false" ]
}

@test "without python3 falls back to plain event forwarding, completely silently" {
  write_home_claude_json '{"mcpServers":{"alpha":{"type":"http","url":"https://alpha.example"}}}'
  run_hook_sandboxed hook-mcp-inventory.sh "$(default_event)" cat sed dirname hostname whoami
  [ "$status" -eq 0 ]
  # the hook runs inside Claude Code where stderr surfaces in the UI on every
  # prompt — the entire output (stdout+stderr) must be exactly the payload JSON
  printf '%s' "$output" | jq -e '.' > /dev/null
  [[ "$output" != *"[Noma]"* ]]
  [ "$(printf '%s' "$output" | jq -r '.prompt')" = "hi" ]
  [ "$(printf '%s' "$output" | jq -r 'has("mcp_artifacts")')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.hostname | length > 0')" = "true" ]
}
