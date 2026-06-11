#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

INPUT=$(cat)

# The inventory is built by mcp-inventory.js via osascript (JXA), which ships
# with every macOS — no extra dependencies. Where osascript is unavailable
# (e.g. Linux) or fails, silently forward the event as-is, exactly like
# hook-curl.sh — the hook runs inside Claude Code, where any stderr output
# surfaces in the UI on every prompt.
PAYLOAD=""
if command -v osascript &>/dev/null; then
  PAYLOAD=$(printf '%s' "$INPUT" | osascript -l JavaScript "$(dirname "$0")/mcp-inventory.js" 2>/dev/null) || PAYLOAD=""
fi

[ -n "$PAYLOAD" ] || PAYLOAD="$INPUT"

noma_post "$(noma_add_host_user "$PAYLOAD")"
