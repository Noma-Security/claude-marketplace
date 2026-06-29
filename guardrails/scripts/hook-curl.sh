#!/usr/bin/env bash
set -euo pipefail

# Resolve NOMA_API_URL (env or default)
NOMA_API_URL="${NOMA_API_URL:-https://api.noma.security}"

# Enforce *.noma.security domain
_noma_host="${NOMA_API_URL#*://}"
_noma_host="${_noma_host%%/*}"
_noma_host="${_noma_host%%:*}"
case "$_noma_host" in
  noma.security|*.noma.security) ;;
  *) echo "[Noma] NOMA_API_URL must point to a *.noma.security host" >&2; exit 1 ;;
esac

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

# Add hostname and username to JSON payload (optional - fails gracefully)
host_name=$(hostname 2>/dev/null) || host_name=""
user_name=$(whoami 2>/dev/null) || user_name=""

extra=""
if [ -n "$host_name" ]; then
  escaped_host=$(printf '%s' "$host_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
  extra="\"hostname\":\"$escaped_host\""
fi
if [ -n "$user_name" ]; then
  escaped_user=$(printf '%s' "$user_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
  [ -n "$extra" ] && extra="$extra,"
  extra="${extra}\"username\":\"$escaped_user\""
fi
if [ -n "$extra" ]; then
  INPUT="${INPUT%\}},$extra}"
fi

RESPONSE=$(curl -fsS --max-time 10 \
  -H "Content-Type: application/json" \
  -H "x-noma-key: Bearer ${NOMA_API_KEY}" \
  -d "$INPUT" \
  "${NOMA_API_URL}/claude/v1/hooks" 2>&1) || { echo "[Noma] $RESPONSE" >&2; exit 1; }

echo "$RESPONSE"
