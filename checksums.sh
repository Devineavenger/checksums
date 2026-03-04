#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# checksums.sh (v3.0 entrypoint)
# Version: 4.1.0
#
# Minimal entrypoint that sources the new modular lib and runs main.
# Preserves the original CLI, usage, and behavior by delegating to lib.
#
# The previous monolithic checksums.sh v2.12.5 has been split into:
#   - lib/init.sh         (defaults, globals, notes)
#   - lib/loader.sh       (dynamic library sourcing)
#   - lib/planner.sh      (planning functions)
#   - lib/orchestrator.sh (full run flow)
# Plus your existing modules in lib/*.sh (fs, hash, logging, meta, process,
# stat, tools, usage, args, compat, first_run).
#
# Notes:
# - This variant preserves comments and diagnostic guidance for maintainers.
# - It declares associative meta_* arrays only when supported by the running shell,
#   avoiding any assignments that would convert arrays to strings (prevents SC2178).
# - All other behavior is preserved from your prior version: quick preview, full plan,
#   first-run scheduling, safe writes with locking, and md5sum-style "./filename" output.

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
  run_checksums
}

main "$@"
