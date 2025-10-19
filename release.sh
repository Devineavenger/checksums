#!/usr/bin/env bash
#
# release.sh — helper to cut a new checksums release
#
# Usage:
#   ./release.sh <version> [--prerelease] [--draft]
#

set -euo pipefail

NEW_VER="${1:-}"
shift || true

PRERELEASE_FLAG=""
DRAFT_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --prerelease) PRERELEASE_FLAG="--prerelease" ;;
    --draft)      DRAFT_FLAG="--draft" ;;
  esac
  shift
done

if [ -z "$NEW_VER" ]; then
  echo "Usage: $0 <new-version> [--prerelease] [--draft]"
  exit 1
fi

echo "==> Releasing version $NEW_VER"

# Step 1: update VERSION file
echo "$NEW_VER" > VERSION
git add VERSION

# Step 2: update version string in checksums.sh header
if grep -q '^# Version:' checksums.sh; then
  sed -i.bak "s/^# Version:.*/# Version: $NEW_VER/" checksums.sh
  rm -f checksums.sh.bak
else
  sed -i.bak "1i# Version: $NEW_VER" checksums.sh
  rm -f checksums.sh.bak
fi
git add checksums.sh

# Step 3: promote [Unreleased] in CHANGELOG.md and reinsert a fresh one
DATE=$(date +"%Y-%m-%d")
if grep -q '^## 

\[Unreleased\]

' CHANGELOG.md 2>/dev/null; then
  echo "==> Promoting [Unreleased] to v$NEW_VER and reinserting new [Unreleased]"
  sed -i.bak "0,/^## 

\[Unreleased\]

/s//## v$NEW_VER - $DATE\n\n## [Unreleased]\n/" CHANGELOG.md
  rm -f CHANGELOG.md.bak
else
  echo "==> No [Unreleased] section found, creating new entry"
  {
    echo "## [Unreleased]"
    echo ""
    echo "## v$NEW_VER - $DATE"
    echo ""
    git log --pretty=format:"* %s" --no-merges
    echo ""
    cat CHANGELOG.md 2>/dev/null || true
  } > CHANGELOG.tmp
  mv CHANGELOG.tmp CHANGELOG.md
fi
git add CHANGELOG.md

# Step 4: commit and tag
git commit -m "Release v$NEW_VER" || echo "Nothing to commit"
git tag -a "v$NEW_VER" -m "Release v$NEW_VER"

# Step 5: build dist tarball
make dist

# Step 6: generate grouped changelog notes for GitHub release
echo "==> Generating grouped changelog notes"
CHANGELOG=""

add_section() {
  local type="$1"
  local title="$2"
  local entries
  entries=$(git log "$LAST_TAG"..HEAD --grep="^$type" --pretty=format:"* %s" --no-merges || true)
  if [ -n "$entries" ]; then
    CHANGELOG="$CHANGELOG\n### $title\n$entries\n"
  fi
}

LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -z "$LAST_TAG" ]; then
  LAST_TAG=$(git rev-list --max-parents=0 HEAD) # first commit
fi

add_section "feat:" "Features"
add_section "fix:" "Fixes"
add_section "docs:" "Documentation"
add_section "chore:" "Chores"
add_section "refactor:" "Refactoring"
add_section "test:" "Tests"

if [ -z "$CHANGELOG" ]; then
  CHANGELOG=$(git log "$LAST_TAG"..HEAD --pretty=format:"* %s" --no-merges)
fi

# Step 7: create GitHub release if gh CLI is available
if command -v gh >/dev/null 2>&1; then
  echo "==> Creating GitHub release"
  gh release create "v$NEW_VER" "dist/checksums-$NEW_VER.tar.gz" \
    --title "v$NEW_VER" \
    --notes "$CHANGELOG" \
    $PRERELEASE_FLAG $DRAFT_FLAG
else
  echo "==> gh CLI not found; skipping GitHub release"
  echo "Changelog for v$NEW_VER:"
  echo "$CHANGELOG"
fi

echo "✅ Release $NEW_VER complete"
