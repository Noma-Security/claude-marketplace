#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common/common.sh
. "$(dirname "$0")/common/common.sh"

INPUT=$(cat)

# The inventory is built by inventory_claude_code.py (stdlib-only, runs on any
# python3; the generic engine is the vendored common/noma_inventory package).
# Where python3 is unavailable — or fails — silently forward the event as-is
# with no mcp_artifacts, exactly like hook-curl.sh: the hook runs inside Claude
# Code, where any stderr surfaces in the UI on every prompt.
PAYLOAD=""
PY="$(command -v python3 2>/dev/null || true)"
# macOS ships /usr/bin/python3 as a Command Line Tools stub that pops a GUI
# installer when CLT is absent; only use that exact path when CLT is actually
# present (xcode-select -p succeeds), so the fallback below stays reachable
# without ever prompting. A real python3 (Homebrew, pyenv, MDM) is used as-is.
if [ -n "$PY" ] && { [ "$(uname)" != Darwin ] || [ "$PY" != /usr/bin/python3 ] || xcode-select -p >/dev/null 2>&1; }; then
  PAYLOAD=$(printf '%s' "$INPUT" | "$PY" -B "$(dirname "$0")/inventory_claude_code.py" 2>/dev/null) || PAYLOAD=""
fi

[ -n "$PAYLOAD" ] || PAYLOAD="$INPUT"

noma_post "$(noma_add_host_user "$PAYLOAD")"
