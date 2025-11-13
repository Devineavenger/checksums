#!/usr/bin/env bash
#
# uninstall.sh — Friendly uninstaller for checksums v2.5
#
# This script removes the checksums tool from /usr/local/bin by default,
# along with its supporting library files from /usr/local/share/checksums.
#
# Usage:
#   ./uninstall.sh             # uninstall from /usr/local
#   PREFIX=/opt ./uninstall.sh # uninstall from /opt/bin and /opt/share/checksums
#

set -e

# Read version from VERSION file or fall back to a default
if [ -r VERSION ]; then
  VERSION="$(<VERSION)"
  VERSION="${VERSION##*[[:space:]]}"   # trim trailing newline/space
else
  VERSION="v3.x"
fi

# Colors for pretty output
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

PREFIX=${PREFIX:-/usr/local}
BINDIR="$PREFIX/bin"
LIBDIR="$PREFIX/share/checksums"

echo -e "${YELLOW}==> Uninstalling checksums ${VERSION}${RESET}"
echo "Target prefix: $PREFIX"

# Remove main script
if [ -f "$BINDIR/checksums" ]; then
  echo -e "${YELLOW}==> Removing $BINDIR/checksums${RESET}"
  rm -f "$BINDIR/checksums"
else
  echo -e "${RED}!! $BINDIR/checksums not found${RESET}"
fi

# Remove library directory
if [ -d "$LIBDIR" ]; then
  echo -e "${YELLOW}==> Removing $LIBDIR${RESET}"
  rm -rf "$LIBDIR"
else
  echo -e "${RED}!! $LIBDIR not found${RESET}"
fi

echo -e "${GREEN}==> Uninstallation complete${RESET}"
