#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

set -euo pipefail

# Defaults (override in CI or environment)
: "${CI_PARALLEL:=32}"
: "${CI_STRICT_LOGS:=false}"

export CI_PARALLEL
export CI_STRICT_LOGS

# Ensure bats is available
if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found on PATH — attempting to install bats-core for CI/local convenience..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    # Prefer bats-core package if available, otherwise fall back to bats
    if apt-cache show bats-core >/dev/null 2>&1; then
      sudo apt-get install -y bats-core
    else
      sudo apt-get install -y bats
    fi
  else
    # Fallback: install bats-core from upstream (portable and consistent)
    git clone https://github.com/bats-core/bats-core.git /tmp/bats-core
    sudo /tmp/bats-core/install.sh /usr/local
    rm -rf /tmp/bats-core
  fi
fi

# Verify bats is now available and print diagnostics for CI logs
if ! command -v bats >/dev/null 2>&1; then
  echo "ERROR: bats not installed or not on PATH after attempted install. Please install bats-core." >&2
  exit 2
fi
echo "Using bats at: $(command -v bats)"
bats --version 2>/dev/null || echo "bats --version unavailable"

echo "Running bats tests with CI_PARALLEL=${CI_PARALLEL} CI_STRICT_LOGS=${CI_STRICT_LOGS}"

# Determine parallel job count for bats: use BATS_JOBS if set, otherwise auto-detect.
# Requires GNU parallel or shenwei356/rush for --jobs support.
: "${BATS_JOBS:=0}"
if [ "$BATS_JOBS" -eq 0 ] && command -v nproc >/dev/null 2>&1; then
  BATS_JOBS=$(nproc)
fi

# Run via the bats binary explicitly to ensure the Bats harness provides helpers like 'fail'
if [ "$BATS_JOBS" -gt 1 ] && command -v parallel >/dev/null 2>&1; then
  echo "Running bats with --jobs $BATS_JOBS (parallel test files)"
  bats --jobs "$BATS_JOBS" tests/
else
  bats tests/
fi
rc=$?

echo
if [ $rc -eq 0 ]; then
  echo "bats: all tests passed"
else
  echo "bats: some tests failed (exit code $rc)"
fi

exit $rc
