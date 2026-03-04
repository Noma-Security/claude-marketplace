#!/usr/bin/env bash
set -euo pipefail

# Resolve NOMA_API_URL (env or default)
NOMA_API_URL="${NOMA_API_URL:-https://api.noma.security}"

# Resolve NOMA_API_KEY (env → macOS keychain → Linux secret-tool)
if [ -z "${NOMA_API_KEY:-}" ]; then
  if command -v security &>/dev/null; then
    NOMA_API_KEY=$(security find-generic-password -s "noma-guardrails" -a "$USER" -w 2>/dev/null || true)
  elif command -v secret-tool &>/dev/null; then
    NOMA_API_KEY=$(secret-tool lookup service noma-guardrails username "$USER" 2>/dev/null || true)
  fi
fi

if [ -z "${NOMA_API_KEY:-}" ]; then
  echo "NOMA_API_KEY not found in environment or keychain. HTTP hooks will receive auth errors." >&2
  exit 1
fi

INPUT=$(cat)

RESPONSE=$(curl -fsS --max-time 10 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${NOMA_API_KEY}" \
  -d "$INPUT" \
  "${NOMA_API_URL}/claude/v1/hooks" 2>&1) || { echo "[Noma] $RESPONSE" >&2; exit 1; }

echo "$RESPONSE"
