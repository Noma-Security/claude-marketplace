# Shared helpers for the guardrails bats suite. Loaded by every .bats file.
#
# Every test runs the hook scripts against a sandbox HOME built from fixtures
# (never the developer's real ~/.claude.json) with NOMA_DRYRUN=1, so no test
# touches the network or the machine's real Claude Code state.
#
# shellcheck disable=SC2154  # $output and $status are provided by bats' run()

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/guardrails/scripts"

# Shell used to execute the hook scripts. CI's macOS job sets
# NOMA_TEST_SHELL=/bin/bash to exercise stock bash 3.2 — what real plugin
# users run.
TEST_SHELL_BIN="${NOMA_TEST_SHELL:-$(command -v bash)}"

setup() {
  TEST_HOME="$(mktemp -d)"
  TEST_PROJECT="$(mktemp -d)"
  export NOMA_API_KEY="test-key"
  export NOMA_DRYRUN=1
  unset NOMA_API_URL
}

teardown() {
  rm -rf "$TEST_HOME" "$TEST_PROJECT"
  if [ -n "${MANAGED_MCP_CREATED:-}" ]; then
    sudo rm -f /etc/claude-code/managed-mcp.json
    unset MANAGED_MCP_CREATED
  fi
}

# --- running hooks ----------------------------------------------------------

# run_hook <script-name> <event-json>
# Pipes the event into the script under the sandbox HOME; $status/$output via
# bats' run (stderr is merged into $output).
run_hook() {
  run bash -c 'printf "%s" "$1" | HOME="$2" "$3" "$4"' _ \
    "$2" "$TEST_HOME" "$TEST_SHELL_BIN" "$SCRIPTS_DIR/$1"
}

# run_hook_sandboxed <script-name> <event-json> <tool...>
# Same, but with PATH restricted to symlinks of exactly the listed tools —
# used to simulate machines without jq / curl / keychain helpers.
run_hook_sandboxed() {
  local script="$1" event="$2" sandbox tool tool_path
  shift 2
  sandbox="$(mktemp -d -p "$TEST_HOME")"
  for tool in "$@"; do
    tool_path="$(command -v "$tool" 2>/dev/null)" && ln -s "$tool_path" "$sandbox/$tool"
  done
  run bash -c 'printf "%s" "$1" | HOME="$2" PATH="$3" "$4" "$5"' _ \
    "$event" "$TEST_HOME" "$sandbox" "$TEST_SHELL_BIN" "$SCRIPTS_DIR/$script"
}

# A minimal valid UserPromptSubmit event with cwd pointing at the sandbox project
default_event() {
  printf '{"hook_event_name":"UserPromptSubmit","prompt":"hi","cwd":"%s","session_id":"test-session"}' "$TEST_PROJECT"
}

# --- fixtures ---------------------------------------------------------------

write_home_claude_json() {
  printf '%s' "$1" > "$TEST_HOME/.claude.json"
}

write_user_mcp_json() {
  mkdir -p "$TEST_HOME/.claude"
  printf '%s' "$1" > "$TEST_HOME/.claude/mcp.json"
}

write_project_mcp_json() {
  printf '%s' "$1" > "$TEST_PROJECT/.mcp.json"
}

# write_settings <absolute-file-path> <json>
write_settings() {
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
}

# add_plugin <name> <config-relpath> <config-json> [scope] [projectPath]
# Creates the plugin cache dir with the given config file and registers it in
# installed_plugins.json the way Claude Code does.
add_plugin() {
  local name="$1" relpath="$2" content="$3" scope="${4:-user}" project_path="${5:-}"
  local dir="$TEST_HOME/.claude/plugins/cache/test-marketplace/$name/1.0.0"
  local registry="$TEST_HOME/.claude/plugins/installed_plugins.json"

  mkdir -p "$dir/$(dirname "$relpath")"
  printf '%s' "$content" > "$dir/$relpath"

  mkdir -p "$TEST_HOME/.claude/plugins"
  [ -f "$registry" ] || printf '%s' '{"plugins":{}}' > "$registry"
  jq --arg key "$name@test-marketplace" --arg path "$dir" --arg scope "$scope" --arg pp "$project_path" \
    '.plugins[$key] = [{installPath: $path, scope: $scope} + (if $pp != "" then {projectPath: $pp} else {} end)]' \
    "$registry" > "$registry.tmp" && mv "$registry.tmp" "$registry"
}

# --- assertions -------------------------------------------------------------

# payload_field <jq-filter> — evaluate a jq filter against the captured payload
payload_field() {
  printf '%s' "$output" | jq -r "$1"
}

# artifact_field <scope> <kind> <jq-filter> — evaluate a filter against the
# single artifact matching scope+kind
artifact_field() {
  printf '%s' "$output" | jq -r --arg s "$1" --arg k "$2" \
    ".mcp_artifacts[] | select(.scope == \$s and .kind == \$k) | $3"
}

# artifact_count [scope [kind]]
artifact_count() {
  printf '%s' "$output" | jq -r --arg s "${1:-}" --arg k "${2:-}" \
    '[.mcp_artifacts[]? | select(($s == "" or .scope == $s) and ($k == "" or .kind == $k))] | length'
}

refute_payload_contains() {
  if printf '%s' "$output" | grep -qF -- "$1"; then
    echo "payload unexpectedly contains: $1" >&2
    echo "payload: $output" >&2
    return 1
  fi
}
