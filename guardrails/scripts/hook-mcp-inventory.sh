#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

INPUT=$(cat)

# Without jq the inventory cannot be built — forward the event as-is,
# exactly like hook-curl.sh
if ! command -v jq &>/dev/null; then
  echo "[Noma] jq not found; sending event without MCP inventory" >&2
  noma_post "$(noma_add_host_user "$INPUT")"
  exit 0
fi

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -n "$CWD" ] || CWD="$PWD"

CLAUDE_JSON="$HOME/.claude.json"

# Shared jq defs.
#   norm            normalize any MCP config file shape to {name: config}:
#                   {"mcpServers": {...}} | {"servers": {...}} | bare {"name": {...}}
#   sanitize_*      best-effort masking of secret-looking values
#   clean_server    per-server field allowlist (type/url/command/args — env,
#                   headers and anything else never leave the machine); strings
#                   are sanitized so the identifier ai-dr derives from them is
#                   clean by construction
#   *_content       artifact content builders; {} means nothing to report and
#                   the artifact is skipped
# shellcheck disable=SC2016  # jq program: $-expressions are jq's, not bash's
JQ_LIB='
  def norm:
    if type == "object" then
      if (.mcpServers? | type == "object") then .mcpServers
      elif (.servers? | type == "object") then .servers
      else with_entries(select(.value | type == "object" and (has("command") or has("url") or has("type")))) end
    else {} end;

  def sanitize_str:
    gsub("(?<k>[A-Za-z0-9_-]*(?i:token|secret|password|passwd|api[_-]?key|apikey|access[_-]?key|credential|auth)[A-Za-z0-9_-]*)=(?<v>[^ \\t]+)"; "\(.k)=***REDACTED***")
    | gsub("(?i:bearer)[ \\t]+[^ \\t\"]+"; "Bearer ***REDACTED***")
    | gsub("\\b(github_pat_|ghp_|gho_|ghu_|ghs_|ghr_|glpat-)[A-Za-z0-9_-]+"; "***REDACTED***")
    | gsub("\\bsk-[A-Za-z0-9_-]{8,}"; "***REDACTED***")
    | gsub("\\bxox[baprs]-[A-Za-z0-9-]+"; "***REDACTED***")
    | gsub("\\bAKIA[0-9A-Z]{16}\\b"; "***REDACTED***")
    | gsub("\\beyJ[A-Za-z0-9_-]{14,}\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "***REDACTED***")
    | gsub("(?<s>[A-Za-z][A-Za-z0-9+.-]*://)[^/@ \\t]+:[^/@ \\t]+@"; "\(.s)***REDACTED***@");

  def sanitize_args:
    . as $a
    | [range(0; length)] | map(
        $a[.] as $v
        | (if . > 0 then $a[. - 1] else null end) as $prev
        | if ($prev | type == "string") and ($prev | test("^--?[A-Za-z0-9-]*(?i:token|secret|password|passwd|api-?key|apikey|access-?key|credential|auth|pat)[A-Za-z0-9-]*$"))
          then "***REDACTED***"
          elif ($v | type == "string") then ($v | sanitize_str)
          else $v end
      );

  def clean_server:
    if type != "object" then {} else
      . as $c
      | (if $c.type != null then {type: $c.type} else {} end)
      + (if ($c.url | type) == "string" then {url: ($c.url | sanitize_str)} else {} end)
      + (if ($c.command | type) == "string" then {command: ($c.command | sanitize_str)} else {} end)
      + (if ($c.args | type) == "array" then {args: ($c.args | sanitize_args | map(if type == "string" then . else tostring end))} else {} end)
    end;

  def clean_map:
    if type == "object" then with_entries(.value |= clean_server) else {} end;

  def wrap_servers:
    if length > 0 then {mcpServers: .} else {} end;

  def server_content: norm | clean_map | wrap_servers;

  def manifest_content:
    (.mcpServers? // {}) | if type == "object" then . else {} end | clean_map | wrap_servers;

  def lists_content:
    if type == "object" then . else {} end
    | {enabledMcpjsonServers, disabledMcpjsonServers}
    | with_entries(select(.value | type == "array" and length > 0));
'

# Defensive read: missing/empty/malformed files degrade to {} ($1=file $2=filter)
read_json() {
  local out
  out=$(jq -c -s "$JQ_LIB (.[0] // {}) | $2" "$1" 2>/dev/null) || out='{}'
  [ -n "$out" ] || out='{}'
  printf '%s\n' "$out"
}

# Append one {scope, kind, path, content} artifact, skipping empty content
# ($1=scope $2=kind $3=path $4=content)
ARTIFACTS='[]'
add_artifact() {
  local updated
  updated=$(jq -cn --argjson a "$ARTIFACTS" --argjson c "$4" --arg s "$1" --arg k "$2" --arg p "$3" '
    if ($c | type) == "object" and ($c | length) > 0
    then $a + [{scope: $s, kind: $k, path: $p, content: $c}]
    else $a end' 2>/dev/null) || return 0
  [ -n "$updated" ] && ARTIFACTS="$updated"
  return 0
}

# User scope in ~/.claude.json: explicit keys only — the file top level is full
# of unrelated (and sensitive) state, so the bare-map heuristic must not run here
add_artifact user claude_json "$CLAUDE_JSON" "$(read_json "$CLAUDE_JSON" \
  '(.mcpServers // .servers // {}) | if type == "object" then . else {} end | clean_map | wrap_servers')"

# Local scope: this project entry in ~/.claude.json — only its MCP keys; the
# entry also holds prompts and metrics that must never be sent
LOCAL_CONTENT=$(jq -c -s --arg c "$CWD" "$JQ_LIB"' (.[0] // {})
  | .projects[$c]? // {} | if type == "object" then . else {} end
  | ((.mcpServers // {} | clean_map | wrap_servers) + lists_content)' \
  "$CLAUDE_JSON" 2>/dev/null) || LOCAL_CONTENT='{}'
[ -n "$LOCAL_CONTENT" ] || LOCAL_CONTENT='{}'
add_artifact local claude_json "$CLAUDE_JSON" "$LOCAL_CONTENT"

# User scope: ~/.claude/mcp.json; project scope: <cwd>/.mcp.json
add_artifact user claude_mcp_json "$HOME/.claude/mcp.json" "$(read_json "$HOME/.claude/mcp.json" 'server_content')"
add_artifact project claude_mcp_json "$CWD/.mcp.json" "$(read_json "$CWD/.mcp.json" 'server_content')"

# Plugin scope: one artifact per installed plugin active for this cwd
while IFS= read -r install_path; do
  [ -n "$install_path" ] || continue
  if [ -f "$install_path/.mcp.json" ]; then
    add_artifact plugin claude_mcp_json "$install_path/.mcp.json" "$(read_json "$install_path/.mcp.json" 'server_content')"
  elif [ -f "$install_path/.claude-plugin/plugin.json" ]; then
    add_artifact plugin claude_mcp_json "$install_path/.claude-plugin/plugin.json" "$(read_json "$install_path/.claude-plugin/plugin.json" 'manifest_content')"
  elif [ -f "$install_path/plugin.json" ]; then
    add_artifact plugin claude_mcp_json "$install_path/plugin.json" "$(read_json "$install_path/plugin.json" 'manifest_content')"
  fi
done < <(jq -r --arg c "$CWD" '
    .plugins // {} | to_entries[] | .value[]?
    | select(.scope != "local" or .projectPath == $c)
    | .installPath // empty
  ' "$HOME/.claude/plugins/installed_plugins.json" 2>/dev/null || true)

# Managed scope (enterprise-deployed)
for f in "/Library/Application Support/ClaudeCode/managed-mcp.json" "/etc/claude-code/managed-mcp.json"; do
  if [ -f "$f" ]; then
    add_artifact managed claude_managed_mcp_json "$f" "$(read_json "$f" 'server_content')"
    break
  fi
done

# Enable/disable lists from settings files
add_artifact user claude_settings_json "$HOME/.claude/settings.json" "$(read_json "$HOME/.claude/settings.json" 'lists_content')"
add_artifact project claude_settings_json "$CWD/.claude/settings.json" "$(read_json "$CWD/.claude/settings.json" 'lists_content')"
add_artifact local claude_settings_json "$CWD/.claude/settings.local.json" "$(read_json "$CWD/.claude/settings.local.json" 'lists_content')"

# Attach the per-file artifacts plus hostname and username to the event
# payload; ai-dr reconstructs the merged per-session inventory from them
PAYLOAD=$(printf '%s' "$INPUT" | jq -c --argjson a "$ARTIFACTS" '. + {mcp_artifacts: $a}' 2>/dev/null) || PAYLOAD=""

if [ -z "$PAYLOAD" ]; then
  PAYLOAD=$(jq -cn --argjson a "$ARTIFACTS" --arg cwd "$CWD" \
    '{hook_event_name: "UserPromptSubmit", cwd: $cwd, mcp_artifacts: $a}')
fi
PAYLOAD=$(noma_add_host_user "$PAYLOAD")

noma_post "$PAYLOAD"
