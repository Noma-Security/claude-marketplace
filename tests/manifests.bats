#!/usr/bin/env bats
# Plugin manifests and script syntax — cheap guards against shipping a broken plugin

load test_helper

@test "all JSON manifests are valid" {
  jq -e '.' "$REPO_ROOT/.claude-plugin/marketplace.json" > /dev/null
  jq -e '.' "$REPO_ROOT/guardrails/.claude-plugin/plugin.json" > /dev/null
  jq -e '.' "$REPO_ROOT/guardrails/hooks/hooks.json" > /dev/null
  jq -e '.' "$REPO_ROOT/guardrails-windows/.claude-plugin/plugin.json" > /dev/null
  jq -e '.' "$REPO_ROOT/guardrails-windows/hooks/hooks.json" > /dev/null
}

@test "hook scripts pass bash -n" {
  bash -n "$SCRIPTS_DIR/common/common.sh"
  bash -n "$SCRIPTS_DIR/hook-curl.sh"
  bash -n "$SCRIPTS_DIR/hook-mcp-inventory.sh"
}

@test "hooks.json wires the expected events to the expected scripts" {
  local hooks="$REPO_ROOT/guardrails/hooks/hooks.json"
  [ "$(jq -r '.hooks | keys | sort | join(",")' "$hooks")" = "PostToolUse,PreToolUse,UserPromptSubmit" ]
  [ "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$hooks")" = '${CLAUDE_PLUGIN_ROOT}/scripts/hook-mcp-inventory.sh' ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$hooks")" = '${CLAUDE_PLUGIN_ROOT}/scripts/hook-curl.sh' ]
  [ "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$hooks")" = '${CLAUDE_PLUGIN_ROOT}/scripts/hook-curl.sh' ]
}

@test "referenced hook scripts exist and are executable" {
  [ -x "$SCRIPTS_DIR/hook-curl.sh" ]
  [ -x "$SCRIPTS_DIR/hook-mcp-inventory.sh" ]
}
