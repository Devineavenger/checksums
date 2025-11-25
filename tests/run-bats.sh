#!/usr/bin/env bash
set -euo pipefail

# Defaults (override in CI or environment)
: "${CI_PARALLEL:=4}"
: "${CI_STRICT_LOGS:=false}"

export CI_PARALLEL
export CI_STRICT_LOGS

# Ensure bats is available
if ! command -v bats >/dev/null 2>&1; then
  echo "Installing bats (apt-get) for CI/local convenience..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y bats
  else
    echo "bats not found and automatic install not available. Please install bats."
    exit 2
  fi
fi

echo "Running bats tests with CI_PARALLEL=${CI_PARALLEL} CI_STRICT_LOGS=${CI_STRICT_LOGS}"
bats tests/
rc=$?

echo
if [ $rc -eq 0 ]; then
  echo "bats: all tests passed"
else
  echo "bats: some tests failed (exit code $rc)"
fi

exit $rc
