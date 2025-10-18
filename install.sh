#!/usr/bin/env bash
# install.sh - installer for checksums v2.2
# Copies the main script and libraries into a prefix (default /usr/local).
# Adjusts BASE_DIR in the installed binary so it can find its lib/ and VERSION.
# Also ensures --version works as expected.

set -euo pipefail

PREFIX=${PREFIX:-/usr/local}
BINDIR="$PREFIX/bin"
LIBDIR="$PREFIX/share/checksums"
VERSION_FILE="VERSION"

echo "Installing checksums into $PREFIX ..."

# Ensure directories exist
mkdir -p "$BINDIR" "$LIBDIR"

# Copy main executable
install -m 0755 checksums.sh "$BINDIR/checksums"

# Copy libraries and version file
rsync -a lib/ "$LIBDIR/lib/"
install -m 0644 "$VERSION_FILE" "$LIBDIR/"

# Patch the BASE_DIR in the installed script to point to LIBDIR
# This ensures the installed binary always sources the right lib/ and VERSION
sed -i.bak "s|^BASE_DIR=.*|BASE_DIR=\"$LIBDIR\"|" "$BINDIR/checksums"
rm -f "$BINDIR/checksums.bak"

echo "Installed:"
echo "  - Executable: $BINDIR/checksums"
echo "  - Libraries:  $LIBDIR/lib/"
echo "  - Version:    $LIBDIR/$VERSION_FILE"

# Quick smoke test: print version
echo
echo "Verifying installation..."
"$BINDIR/checksums" --version || true
