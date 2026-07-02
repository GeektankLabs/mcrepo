#!/usr/bin/env bash
# Run the mcrepo test suite.
#
# Usage:
#   tests/run.sh              # run all tests
#   tests/run.sh 00-smoke     # run a single suite (name or file)
#
# Resolves bats from PATH, falls back to a pinned npx version.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BATS_VERSION_PIN="1.11.0"

resolve_bats() {
  if command -v bats >/dev/null 2>&1; then
    echo "bats"
    return 0
  fi
  if command -v npx >/dev/null 2>&1; then
    echo "npx --yes bats@${BATS_VERSION_PIN}"
    return 0
  fi
  echo "Error: bats not found and npx unavailable. Install bats-core (https://github.com/bats-core/bats-core)." >&2
  return 1
}

bats_cmd="$(resolve_bats)"

targets=()
if [ "$#" -eq 0 ]; then
  targets=("$TESTS_DIR"/*.bats)
else
  for arg in "$@"; do
    if [ -f "$arg" ]; then
      targets+=("$arg")
    elif [ -f "$TESTS_DIR/$arg" ]; then
      targets+=("$TESTS_DIR/$arg")
    elif [ -f "$TESTS_DIR/$arg.bats" ]; then
      targets+=("$TESTS_DIR/$arg.bats")
    else
      echo "Error: no such test suite: $arg" >&2
      exit 1
    fi
  done
fi

exec $bats_cmd --timing "${targets[@]}"
