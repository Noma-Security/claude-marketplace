#!/usr/bin/env bash
set -euo pipefail

# Run the python unit suite across every supported Python 3 using the official
# docker images — the same matrix CI runs. Docker is a dev-only dependency; the
# hook itself needs no docker and no third-party packages.
#
# Usage:
#   scripts/test-python-matrix.sh              # all versions below
#   scripts/test-python-matrix.sh 3.6 3.13     # just these

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -gt 0 ]; then
  VERSIONS=("$@")
else
  VERSIONS=(3.6 3.7 3.8 3.9 3.10 3.11 3.12 3.13 3.14)
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run the python version matrix" >&2
  exit 2
fi

status=0
for v in "${VERSIONS[@]}"; do
  echo "===== python:$v ====="
  if docker run --rm -v "$REPO_ROOT":/w -w /w "python:$v" sh -c '
    python -V &&
    python -m py_compile common/noma_inventory/*.py guardrails/scripts/inventory_claude_code.py &&
    python -m unittest discover -s tests/python -p "test_*.py"'; then
    echo "PASS python:$v"
  else
    echo "FAIL python:$v" >&2
    status=1
  fi
done

exit "$status"
