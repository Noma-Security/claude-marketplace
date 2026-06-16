#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common/common.sh
. "$(dirname "$0")/common/common.sh"

INPUT=$(cat)

noma_post "$(noma_add_host_user "$INPUT")"
