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
# install.sh — Friendly installer for checksums
#
# Usage:
#   ./install.sh            # install to /usr/local
#   PREFIX=/opt ./install.sh  # install to /opt/bin and /opt/share/checksums
#

set -e

# Read version from VERSION file or fall back to a default
if [ -r VERSION ]; then
  VERSION="$(<VERSION)"
  VERSION="${VERSION##*[[:space:]]}"   # trim trailing newline/space
else
  VERSION="v3.x"
fi

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

PREFIX=${PREFIX:-/usr/local}
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/checksums"
LIBSUBDIR="$SHAREDIR/lib"

echo -e "${YELLOW}==> Installing checksums ${VERSION}${RESET}"
echo "Target prefix: $PREFIX"

# Ensure writable or warn
if [ ! -w "$PREFIX" ] && [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}ERROR${RESET}: No write permission for $PREFIX. Run as root or choose another PREFIX." >&2
  exit 1
fi

echo -e "${YELLOW}==> Creating directories${RESET}"
mkdir -p "$BINDIR" "$LIBSUBDIR"

# Install VERSION so runtime can read the packaged version string
install -m 0644 VERSION "$SHAREDIR/"

echo -e "${YELLOW}==> Installing main script to $BINDIR${RESET}"
install -m 0755 checksums.sh "$BINDIR/checksums"

echo -e "${YELLOW}==> Installing library files to $LIBSUBDIR${RESET}"
install -m 0644 lib/*.sh "$LIBSUBDIR/"

# Detect OS for friendly message
OS="$(uname -s)"
case "$OS" in
  Darwin) echo -e "${GREEN}✔ Installed on macOS${RESET}" ;;
  Linux)  echo -e "${GREEN}✔ Installed on Linux${RESET}" ;;
  *)      echo -e "${GREEN}✔ Installed on $OS${RESET}" ;;
esac

echo -e "${GREEN}==> Installation complete! (checksums ${VERSION})${RESET}"
echo "Run 'checksums --help' to get started."
