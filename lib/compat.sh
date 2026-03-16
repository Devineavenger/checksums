#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# compat.sh
#
# Shell compatibility helpers.
#
# Responsibilities:
# - Enforce Bash 4.0+ at startup (required for associative arrays).
# - Provide a clear error message and install hint on older Bash (e.g. macOS stock 3.2).

# check_bash_version — Verify Bash >= 4.0 (required for associative arrays).
# Called once at startup from each entry point (run_checksums, run_status, run_check_mode).
# Fatals with a clear message and install hints if the version is too old.
check_bash_version() {
  local major=${BASH_VERSINFO[0]:-0}
  if [ "$major" -lt 4 ]; then
    printf 'ERROR: checksums requires Bash 4.0 or later (found %s).\n' "${BASH_VERSION:-unknown}" >&2
    printf 'On macOS, install a newer Bash: brew install bash\n' >&2
    exit 1
  fi
}
