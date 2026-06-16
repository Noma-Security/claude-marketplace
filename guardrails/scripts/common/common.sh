#!/usr/bin/env bash
# Shared logic for Noma guardrails hook scripts — source, do not execute.

# Resolve NOMA_API_URL (env or default)
# TEMPORARY (local development): default points at a local ai-dr and the
# *.noma.security domain enforcement is disabled. Restore both before release:
#   NOMA_API_URL="${NOMA_API_URL:-https://api.noma.security}"
#   + the case-statement host check (see tests/common.bats skipped tests)
NOMA_API_URL="${NOMA_API_URL:-http://localhost:18000}"

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

# Append hostname and username to a JSON object (optional - fails gracefully)
noma_add_host_user() {
  local json="$1" host_name user_name extra escaped
  host_name=$(hostname 2>/dev/null) || host_name=""
  user_name=$(whoami 2>/dev/null) || user_name=""

  extra=""
  if [ -n "$host_name" ]; then
    escaped=$(printf '%s' "$host_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
    extra="\"hostname\":\"$escaped\""
  fi
  if [ -n "$user_name" ]; then
    escaped=$(printf '%s' "$user_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
    [ -n "$extra" ] && extra="$extra,"
    extra="${extra}\"username\":\"$escaped\""
  fi
  if [ -n "$extra" ]; then
    json="${json%\}},$extra}"
  fi
  printf '%s\n' "$json"
}

# POST a payload to the Noma hooks endpoint; prints the API response.
# With NOMA_DRYRUN set, prints the payload instead of sending it.
noma_post() {
  local response
  if [ -n "${NOMA_DRYRUN:-}" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  response=$(curl -fsS --max-time 10 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${NOMA_API_KEY}" \
    -d "$1" \
    "${NOMA_API_URL}/claude/v1/hooks" 2>&1) || { echo "[Noma] $response" >&2; return 1; }
  printf '%s\n' "$response"
}
