#!/usr/bin/env bash
set -euo pipefail

# Simple runner for Cadence tests that executes each test file
# individually to avoid contract-overwrite conflicts in the Flow emulator.
# Usage: ./run_tests.sh

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$ROOT_DIR/cadence/tests"

EXIT_CODE=0

while IFS= read -r -d '' test_file; do
  echo "📝 Running: ${test_file#$ROOT_DIR/}"
  if flow test "$test_file"; then
    echo "✅ PASSED: ${test_file#$ROOT_DIR/}"
  else
    echo "❌ FAILED: ${test_file#$ROOT_DIR/}"
    EXIT_CODE=1
  fi
  # Clean emulator state between tests to avoid contract collisions
  rm -rf "$HOME/.flow"
done < <(find "$TEST_DIR" -maxdepth 1 -type f -name '*_test.cdc' -print0)

exit $EXIT_CODE
