#!/usr/bin/env bash
set -euo pipefail

# Vendors the shared common/ folder into each consuming plugin's scripts/common/
# so every plugin ships a self-contained copy. Claude Code installs each plugin
# directory independently — there is no shared sibling available at runtime, so
# the single source of truth in common/ must be copied in.
#
# Usage:
#   scripts/sync-common.sh            copy common/ -> <plugin>/scripts/common/
#   scripts/sync-common.sh --check    fail (exit 1) if any copy has drifted
#
# CI runs --check so the vendored copies can never silently diverge from common/.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/common"

# Plugins that consume the shared python inventory + bash helpers. The Windows
# plugin (PowerShell) and a future Cursor plugin are added here once they ship a
# python3 entry hook that sources common/.
PLUGINS=(guardrails)

CHECK=0
if [ "${1:-}" = "--check" ]; then
  CHECK=1
elif [ -n "${1:-}" ]; then
  echo "usage: $0 [--check]" >&2
  exit 2
fi

status=0
for plugin in "${PLUGINS[@]}"; do
  dest="$REPO_ROOT/$plugin/scripts/common"
  if [ "$CHECK" -eq 1 ]; then
    # diff -r flags missing, extra, and differing files in one shot. Ignore
    # python bytecode caches written at runtime.
    if ! diff -r -x __pycache__ -x '*.pyc' "$SRC" "$dest" >/dev/null 2>&1; then
      echo "drift: $plugin/scripts/common differs from common/ — run scripts/sync-common.sh" >&2
      diff -r -x __pycache__ -x '*.pyc' "$SRC" "$dest" >&2 || true
      status=1
    fi
  else
    rm -rf "$dest"
    mkdir -p "$dest"
    cp -R "$SRC/." "$dest/"
    # Never vendor python bytecode caches (a test run may leave them in common/).
    find "$dest" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
    find "$dest" -type f -name '*.pyc' -delete 2>/dev/null || true
    echo "synced common/ -> $plugin/scripts/common/"
  fi
done

exit "$status"
