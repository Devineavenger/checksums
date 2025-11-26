#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# Convert common text files from CRLF to LF across the repository.
# Skips .git directory. Falls back to a Perl in-place conversion if dos2unix is not available.
set -euo pipefail

# Detect dos2unix; fall back to perl if missing
if command -v dos2unix >/dev/null 2>&1; then
  CONVERTER="dos2unix"
else
  CONVERTER="perl"
fi

# Patterns to convert
patterns=(
  "*.bats"
  "*.sh"
  "Makefile"
  "*.yml"
  "*.bash"
  "*.json"
  "*.swp"
)

# Run conversion for each pattern, excluding .git
for pat in "${patterns[@]}"; do
  if [ "$CONVERTER" = "dos2unix" ]; then
    # Use -print0 and xargs -0 to handle filenames with spaces/newlines
    find . -type f -name "$pat" -not -path '*/.git/*' -print0 \
      | xargs -0 --no-run-if-empty dos2unix --
  else
    # Perl fallback: replace CRLF with LF in-place
    find . -type f -name "$pat" -not -path '*/.git/*' -print0 \
      | while IFS= read -r -d '' file; do
          # Use perl to convert CRLF -> LF safely
          perl -0777 -pe 's/\r\n/\n/g' -i -- "$file"
        done
  fi
done

echo "dos2unix conversion complete."
