#!/usr/bin/env bash
#
# release.sh — helper to cut a new checksums release
#
# Usage:
#   ./release.sh <version> [--prerelease] [--draft]
#
# This script:
#   1. Updates the VERSION file
#   2. Updates the version header in checksums.sh
#   3. Updates the version header AND fallback in lib/init.sh
#   4. Promotes the [Unreleased] section in CHANGELOG.md
#   5. Builds the dist tarball
#   6. Commits and tags the release
#   7. Pushes branch and tag to origin
#   8. Optionally creates a GitHub Release via API and uploads the tarball
#
# Notes on init.sh update:
#   - It updates the header line starting with "# Version:" to the new version.
#   - It also updates the fallback echo in: VER="$(cat "$BASE_DIR/VERSION" ... || echo "X.Y.Z")"
#     so that if VERSION is missing, the fallback matches the new release.

set -euo pipefail

NEW_VER="${1:-}"
shift || true

PRERELEASE_FLAG=""
DRAFT_FLAG=""

# Parse optional flags
while [ $# -gt 0 ]; do
  case "$1" in
    --prerelease) PRERELEASE_FLAG="true" ;;
    --draft)      DRAFT_FLAG="true" ;;
    *) ;;
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

# Step 2: update version string in checksums.sh header (if present)
if [ -f checksums.sh ]; then
  if grep -q '^# Version:' checksums.sh; then
    sed -i.bak "s/^# Version:.*/# Version: ${NEW_VER}/" checksums.sh
    rm -f checksums.sh.bak
  else
    awk -v new="# Version: ${NEW_VER}" 'NR==2{print;print new;next}1' \
      checksums.sh > checksums.sh.tmp && mv checksums.sh.tmp checksums.sh
  fi
  git add checksums.sh
fi

# Step 3: update version header AND fallback in lib/init.sh
if [ -f lib/init.sh ]; then
  echo "==> Updating lib/init.sh version header and fallback"
  cp lib/init.sh lib/init.sh.bak

  # Update "# Version: ..." header
  if grep -q '^# Version:' lib/init.sh; then
    sed 's/^# Version:.*/# Version: '"${NEW_VER}"'/' lib/init.sh.bak > lib/init.sh.tmp.header || true
  else
    # Insert header after the shebang line if missing
    awk -v new="# Version: ${NEW_VER}" 'NR==1{print;print new;next}1' lib/init.sh.bak > lib/init.sh.tmp.header
  fi

  # Update VER fallback: VER="$(cat "$BASE_DIR/VERSION" 2>/dev/null || echo "X.Y.Z")"
  # Replace the string inside echo "..." with NEW_VER, preserving the rest
  awk -v ver="${NEW_VER}" '
    {
      if ($0 ~ /VER=.*echo[[:space:]]*\"[^\"]*\"[[:space:]]*\)/) {
        # Replace only the fallback number inside the echo "..."
        gsub(/VER=.*echo[[:space:]]*\"[0-9]+\.[0-9]+\.[0-9]+\"[[:space:]]*\)/,
             "VER=\"$(cat \"$BASE_DIR/VERSION\" 2>/dev/null || echo \"" ver "\")\"")
      }
      print
    }
  ' lib/init.sh.tmp.header > lib/init.sh

  rm -f lib/init.sh.bak lib/init.sh.tmp.header
  git add lib/init.sh
else
  echo "==> lib/init.sh not found; skipping init version update"
fi

# Step 4: promote [Unreleased] in CHANGELOG.md and reinsert a fresh one
DATE=$(date +"%Y-%m-%d")

if [ -f CHANGELOG.md ] && grep -q '^## 

\[Unreleased\]

' CHANGELOG.md 2>/dev/null; then
  echo "==> Promoting [Unreleased] to v$NEW_VER and reinserting new [Unreleased]"
  awk -v ver="$NEW_VER" -v date="$DATE" '
    BEGIN { inserted_top = 0; promoted = 0 }
    NR == 1 && inserted_top == 0 {
      print "## [Unreleased]"
      print ""
      inserted_top = 1
    }
    promoted == 0 && index($0, "## [Unreleased]") == 1 {
      print "## v" ver " - " date
      promoted = 1
      next
    }
    { print }
  ' CHANGELOG.md > CHANGELOG.tmp && mv CHANGELOG.tmp CHANGELOG.md
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

# Step 5: build dist tarball BEFORE committing so artifacts are included
echo "==> Building dist tarball"
make dist

# Step 6: commit and tag locally (include all changes)
git add -A

# Ensure commit author is set
git config user.name "${GIT_USER_NAME:-$(git config user.name || echo "release-bot")}"
git config user.email "${GIT_USER_EMAIL:-$(git config user.email || echo "release-bot@example.com")}"

# Commit only if there are staged changes
if ! git diff --cached --quiet; then
  git commit -m "Release v${NEW_VER}"
else
  echo "Nothing to commit"
fi

# Create annotated tag for the release (overwrite if tag already exists locally)
if git rev-parse "refs/tags/v${NEW_VER}" >/dev/null 2>&1; then
  git tag -d "v${NEW_VER}" || true
fi
git tag -a "v${NEW_VER}" -m "Release v${NEW_VER}"

# Step 6.5: determine branch to push from (handle detached HEAD)
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD || true)"
if [ "$CURRENT_BRANCH" = "HEAD" ] || [ -z "$CURRENT_BRANCH" ]; then
  RELEASE_BRANCH="release/v${NEW_VER}"
  echo "==> Detached HEAD detected; creating branch $RELEASE_BRANCH from current commit"
  git checkout -b "$RELEASE_BRANCH"
  CURRENT_BRANCH="$RELEASE_BRANCH"
fi

# Step 7: push commit and tag to origin
echo "==> Pushing commit and tag to origin (branch: $CURRENT_BRANCH)"
git push origin "$CURRENT_BRANCH"
git push origin "v${NEW_VER}"

# Step 8: generate grouped changelog notes for GitHub release
echo "==> Generating grouped changelog notes"
CHANGELOG=""

add_section() {
  local type="$1"
  local title="$2"
  local entries
  entries=$(git log "$LAST_TAG"..HEAD --grep="^$type" --pretty=format:"* %s" --no-merges || true)
  if [ -n "$entries" ]; then
    CHANGELOG="${CHANGELOG}\n### ${title}\n${entries}\n"
  fi
}

LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -z "$LAST_TAG" ]; then
  LAST_TAG=$(git rev-list --max-parents=0 HEAD)
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

# Step 9: create GitHub release via REST API if token present and upload artifact
GHTOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -n "$GHTOKEN" ]; then
  echo "==> Creating GitHub release via REST API"

  ORIGIN_URL="$(git remote get-url origin)"
  if echo "$ORIGIN_URL" | grep -q ':'; then
    REPO="$(echo "$ORIGIN_URL" | sed -n 's#.*[:/]\([^/]*\)/\([^/.]*\)\(\.git\)\?$#\1/\2#p')"
  else
    REPO="$(echo "$ORIGIN_URL" | sed -n 's#.*github.com[:/]\([^/]*\)/\([^/.]*\)\(\.git\)\?$#\1/\2#p')"
  fi

  NOTES="$(printf "%b\n" "$CHANGELOG" | sed 's/"/\\"/g')"
  PRERELEASE_JSON=false
  DRAFT_JSON=false
  if [ -n "$PRERELEASE_FLAG" ]; then PRERELEASE_JSON=true; fi
  if [ -n "$DRAFT_FLAG" ]; then DRAFT_JSON=true; fi

  read -r -d '' PAYLOAD <<EOF || true
{
  "tag_name":"v${NEW_VER}",
  "name":"v${NEW_VER}",
  "body":"${NOTES}",
  "draft": ${DRAFT_JSON},
  "prerelease": ${PRERELEASE_JSON}
}
EOF

  HTTP_STATUS="$(curl -s -o /tmp/gh_release_response.json -w "%{http_code}" -X POST "https://api.github.com/repos/${REPO}/releases" \
    -H "Authorization: token ${GHTOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")"

  if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
    echo "==> GitHub release created successfully"
    if [ -f "dist/checksums-${NEW_VER}.tar.gz" ]; then
      UPLOAD_URL="$(jq -r '.upload_url' /tmp/gh_release_response.json | sed -e 's/{?name,label}//')"
      if [ -n "$UPLOAD_URL" ] && [ "$UPLOAD_URL" != "null" ]; then
        echo "==> Uploading dist/checksums-${NEW_VER}.tar.gz"
        curl --silent --output /dev/null -X POST "${UPLOAD_URL}?name=checksums-${NEW_VER}.tar.gz" \
          -H "Authorization: token ${GHTOKEN}" \
          -H "Content-Type: application/gzip" \
          --data-binary @"dist/checksums-${NEW_VER}.tar.gz" \
          && echo "==> Artifact uploaded"
      else
        echo "==> No valid upload_url in API response; skipping asset upload"
      fi
    else
      echo "==> dist/checksums-${NEW_VER}.tar.gz not found; skipping asset upload"
    fi
  else
    echo "==> GitHub release creation failed (status: $HTTP_STATUS); response saved to /tmp/gh_release_response.json"
    echo "Response preview:"
    head -n 100 /tmp/gh_release_response.json || true
  fi
else
  echo "==> No GH_TOKEN/GITHUB_TOKEN provided; skipping API release step"
  echo "Changelog for v$NEW_VER:"
  printf "%b\n" "$CHANGELOG"
fi

echo "✅ Release $NEW_VER complete"
