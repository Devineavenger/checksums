#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# loader.sh
#
# Library loader for checksums v3.0.
# Searches candidate lib directories and sources all .sh files,
# but skips init.sh and loader.sh themselves to avoid recursion.
#
# This keeps parity with v2.12.5 behavior where the script could be
# installed in /usr/local/bin while its libraries lived in /usr/local/share/checksums/lib.

CANDIDATES=(
  "$BASE_DIR/lib"
  "/usr/local/share/checksums/lib"
  "/usr/share/checksums/lib"
)

sourced_any=0
# Tell ShellCheck we intentionally source dynamic files from lib paths
# shellcheck source=/dev/null
for cand in "${CANDIDATES[@]}"; do
  if [ -d "$cand" ]; then
    for lib in "$cand"/*.sh; do
      case "$(basename "$lib")" in
        init.sh|loader.sh|checksums.sh) continue ;;  # skip self to prevent infinite loop
      esac
      [ -f "$lib" ] && . "$lib"
    done
    sourced_any=1
    break
  fi
done

if [ "$sourced_any" -eq 0 ]; then
  echo "FATAL: no library files found; expected under one of:" >&2
  printf '  %s\n' "${CANDIDATES[@]}" >&2
  exit 2
fi
