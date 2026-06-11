#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

INPUT=$(cat)

noma_post "$(noma_add_host_user "$INPUT")"
