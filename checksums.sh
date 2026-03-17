#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# checksums.sh — modular entrypoint
# Version: 6.2.0
#
# Sources lib/init.sh (globals, defaults) and lib/loader.sh (dynamic library
# sourcing for all other lib/*.sh modules), then calls main().
# CLI parsing, orchestration, and all processing are delegated to lib/.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Source libraries ===
# Preserve original candidate search paths so installation under /usr/local/share works.
CANDIDATES=(
  "$BASE_DIR/lib"
  "/usr/local/share/checksums/lib"
  "/usr/share/checksums/lib"
)

sourced_any=0
for d in "${CANDIDATES[@]}"; do
  if [ -d "$d" ]; then
    # shellcheck source=/dev/null
    . "$d/init.sh"
	# shellcheck source=lib/loader.sh
    . "$d/loader.sh"
    sourced_any=1
    break
  fi
done

if [ "$sourced_any" -eq 0 ]; then
  echo "FATAL: no library files found; expected under one of:" >&2
  printf '  %s\n' "${CANDIDATES[@]}" >&2
  exit 2
fi

main() {
  parse_args "$@"
  if [ "${MENU_MODE:-0}" -eq 1 ]; then
    run_menu
  elif [ -n "${CHECK_FILE:-}" ]; then
    run_check_mode
  elif [ "${STATUS_ONLY:-0}" -eq 1 ]; then
    run_status
  else
    run_checksums
  fi
}

main "$@"
