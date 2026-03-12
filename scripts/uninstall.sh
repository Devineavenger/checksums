#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

#
# uninstall.sh — Friendly uninstaller for checksums
#
# Purpose:
#   Remove the installed checksums command and its supporting library files.
#   This script targets $PREFIX (default /usr/local) and removes:
#     - $PREFIX/bin/checksums
#     - $PREFIX/share/checksums
#
# Behavior:
#   - Determines the package version for friendly output using the same
#     lookup order as the runtime (init.sh):
#       1) $PREFIX/share/checksums/VERSION (preferred)
#       2) a "Version: X.Y.Z" comment in a local checksums.sh (source checkout)
#       3) a "Version: X.Y.Z" comment in the installed wrapper $PREFIX/bin/checksums
#       4) fallback literal "v3.x"
#   - Performs best-effort removal; missing files/directories are reported but not fatal.
#   - Safe to run from checkout (where ./checksums.sh exists) or on an installed system.
#
# Usage:
#   ./uninstall.sh             # uninstall from /usr/local
#   PREFIX=/opt ./uninstall.sh # uninstall from /opt/bin and /opt/share/checksums
#
# Notes:
#   - The lookup mirrors init.sh's preference for an on-disk VERSION file in the
#     installed share directory. That makes the version visible to admins and
#     consistent across install/uninstall messages.
#   - Removal is recursive for the library directory; exercise caution if you
#     manually placed other files under the same prefix.
#

set -euo pipefail

# Default prefix (override with PREFIX=/opt ...)
PREFIX=${PREFIX:-/usr/local}
BINDIR="$PREFIX/bin"
LIBDIR="$PREFIX/share/checksums"

# determine_version:
#  - Try to read an installed VERSION file (preferred, same as init.sh).
#  - If absent, try to extract a "Version: ..." comment from a local copy of checksums.sh.
#  - If still absent, try the installed wrapper at $BINDIR/checksums.
#  - Fall back to 'v3.x' as a safe default.
determine_version() {
  local vfile candidate verline content
  vfile="$LIBDIR/VERSION"

  # 1) Prefer installed VERSION file (strip trailing whitespace/newline)
  if [ -r "$vfile" ]; then
    content="$(<"$vfile")"
    # Trim trailing whitespace/newline and print
    printf '%s' "${content%"${content##*[![:space:]]}"}"
    return 0
  fi

  # 2) Check for Version comment in local source checkout (useful when running uninstall from repo)
  if [ -r "./checksums.sh" ]; then
    # Read first 20 lines and look for "# Version: ...", case-insensitive
    verline="$(sed -n '1,20p' ./checksums.sh 2>/dev/null | grep -i '^# *Version:' || true)"
    if [ -n "$verline" ]; then
      # Extract text after "Version:" and print it
      printf '%s' "$(echo "$verline" | sed -E 's/^# *Version:[[:space:]]*//I')"
      return 0
    fi
  fi

  # 3) Check for Version comment in installed wrapper (BINDIR/checksums)
  if [ -r "$BINDIR/checksums" ]; then
    verline="$(sed -n '1,20p' "$BINDIR/checksums" 2>/dev/null | grep -i '^# *Version:' || true)"
    if [ -n "$verline" ]; then
      printf '%s' "$(echo "$verline" | sed -E 's/^# *Version:[[:space:]]*//I')"
      return 0
    fi
  fi

  # 4) Final fallback
  printf 'v3.x'
}

# Determine version string for friendly output
VERSION="$(determine_version)"

# Colors for pretty output
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

# Informational header
echo -e "${YELLOW}==> Uninstalling checksums ${VERSION}${RESET}"
echo "Target prefix: $PREFIX"

# Remove main script
if [ -f "$BINDIR/checksums" ]; then
  echo -e "${YELLOW}==> Removing $BINDIR/checksums${RESET}"
  rm -f "$BINDIR/checksums"
else
  echo -e "${RED}!! $BINDIR/checksums not found${RESET}"
fi

# Remove man page
MANDIR="$PREFIX/share/man/man1"
if [ -f "$MANDIR/checksums.1" ]; then
  echo -e "${YELLOW}==> Removing $MANDIR/checksums.1${RESET}"
  rm -f "$MANDIR/checksums.1"
fi

# Remove library directory (recursively)
if [ -d "$LIBDIR" ]; then
  echo -e "${YELLOW}==> Removing $LIBDIR${RESET}"
  rm -rf "$LIBDIR"
else
  echo -e "${RED}!! $LIBDIR not found${RESET}"
fi

echo -e "${GREEN}==> Uninstallation complete${RESET}"
