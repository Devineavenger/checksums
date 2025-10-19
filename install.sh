#!/usr/bin/env bash
#
# install.sh — Friendly installer for checksums v2.5
#
# This script installs the checksums tool into /usr/local/bin by default,
# along with its supporting library files into /usr/local/share/checksums.
# It provides clear messages, color output, and OS detection.
#
# Usage:
#   ./install.sh            # install to /usr/local
#   PREFIX=/opt ./install.sh  # install to /opt/bin and /opt/share/checksums
#

set -e

# Colors for pretty output
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

PREFIX=${PREFIX:-/usr/local}
BINDIR="$PREFIX/bin"
LIBDIR="$PREFIX/share/checksums"

echo -e "${YELLOW}==> Installing checksums v2.5${RESET}"
echo "Target prefix: $PREFIX"

# Ensure directories exist
echo -e "${YELLOW}==> Creating directories${RESET}"
mkdir -p "$BINDIR" "$LIBDIR"

# Install main script
echo -e "${YELLOW}==> Installing main script to $BINDIR${RESET}"
install -m 0755 checksums.sh "$BINDIR/checksums"

# Install library files
echo -e "${YELLOW}==> Installing library files to $LIBDIR${RESET}"
install -m 0644 lib/*.sh "$LIBDIR"

# Detect OS for friendly message
OS="$(uname -s)"
case "$OS" in
  Darwin) echo -e "${GREEN}✔ Installed on macOS${RESET}" ;;
  Linux)  echo -e "${GREEN}✔ Installed on Linux${RESET}" ;;
  *)      echo -e "${GREEN}✔ Installed on $OS${RESET}" ;;
esac

echo -e "${GREEN}==> Installation complete!${RESET}"
echo "Run 'checksums --help' to get started."
