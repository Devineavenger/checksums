#!/usr/bin/env bash
# scripts/release.sh — helper to cut a new checksums release
# Usage:
#   ./scripts/release.sh <version> [--prerelease] [--draft]
#
# Notes:
#  - Updates VERSION, checksums.sh header, lib/init.sh header/fallback
#  - Promotes [Unreleased] in docs/CHANGELOG.md (moved to docs/)
#  - Builds dist, commits, tags, pushes, and optionally creates a GitHub release
set -euo pipefail

# Canonical repo root (derive if not provided)
BASE_DIR="${BASE_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Quick tool checks
for cmd in git curl tar mktemp awk sed grep; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required tool '$cmd' not found"; exit 1; }
done

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
  # If no version was provided, try to determine one automatically:
  # 1) Use VERSION file if present
  # 2) Else derive from latest git tag (vMAJOR.MINOR.PATCH) and bump patch
  if [ -f VERSION ]; then
    NEW_VER="$(tr -d ' \t\n\r' < VERSION)"
    echo "No version argument provided; using VERSION file: ${NEW_VER}"
  else
    # Try to get the latest tag and bump patch
    latest_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -n "$latest_tag" ]; then
      # strip leading v if present
      base="${latest_tag#v}"
      IFS='.' read -r major minor patch <<< "$base"
      major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
      # ensure numeric fallback
      case "$patch" in ''|*[!0-9]*) patch=0 ;; esac
      patch=$((patch + 1))
      NEW_VER="${major}.${minor}.${patch}"
      echo "No version argument provided; derived NEW_VER from latest tag ${latest_tag} -> ${NEW_VER}"
    else
      echo "ERROR: no version provided, no VERSION file, and no git tags to derive a version from." >&2
      echo "Please provide a version argument (e.g. ./scripts/release.sh 1.2.3) or create a VERSION file." >&2
      exit 1
    fi
  fi
fi

echo "==> Releasing version $NEW_VER"

# Step 1: update VERSION file
printf '%s\n' "$NEW_VER" > VERSION
git add VERSION

# Step 2: update version string in checksums.sh header (if present)
if [ -f checksums.sh ]; then
  echo "==> Updating checksums.sh header to ${NEW_VER}"
  if grep -q '^# Version:' checksums.sh; then
    # portable: write to temp then move
    tmp="$(mktemp checksums.sh.tmp.XXXXXX)"
    awk -v v="$NEW_VER" '{
      if (NR==1 && $0 ~ /^# Version:/) { sub(/^# Version:.*/, "# Version: " v) }
      print
    }' checksums.sh > "$tmp" && mv "$tmp" checksums.sh
  else
    # insert header after shebang if present, else at top
    tmp="$(mktemp checksums.sh.tmp.XXXXXX)"
    first="$(head -n1 checksums.sh || true)"
    if [ "${first#\#!}" != "$first" ]; then
      # has shebang
      printf '%s\n' "$first" > "$tmp"
      printf '# Version: %s\n' "$NEW_VER" >> "$tmp"
      tail -n +2 checksums.sh >> "$tmp"
    else
      printf '# Version: %s\n' "$NEW_VER" > "$tmp"
      cat checksums.sh >> "$tmp"
    fi
    mv "$tmp" checksums.sh
  fi
  git add checksums.sh
fi

# Step 3: safely update lib/init.sh header and VER fallback
if [ -f lib/init.sh ]; then
  echo "==> Updating lib/init.sh header and VER fallback to ${NEW_VER}"
  cp lib/init.sh lib/init.sh.bak

  # 3a: update or insert header line "# Version: X.Y.Z"
  if grep -q '^# Version:' lib/init.sh; then
    tmp="$(mktemp lib.init.tmp.XXXXXX)"
    awk -v v="$NEW_VER" '{
      if ($0 ~ /^# Version:/ && !done) { print "# Version: " v; done=1; next }
      print
    }' lib/init.sh > "$tmp" && mv "$tmp" lib/init.sh
  else
    tmp="$(mktemp lib.init.tmp.XXXXXX)"
    first="$(head -n1 lib/init.sh || true)"
    if [ "${first#\#!}" != "$first" ]; then
      # insert after shebang
      printf '%s\n' "$first" > "$tmp"
      printf '# Version: %s\n' "$NEW_VER" >> "$tmp"
      tail -n +2 lib/init.sh >> "$tmp"
    else
      printf '# Version: %s\n' "$NEW_VER" > "$tmp"
      cat lib/init.sh >> "$tmp"
    fi
    mv "$tmp" lib/init.sh
  fi

  # 3b: replace the first printf fallback line like: printf '%s' "1.2.3"
  echo "==> Patching lib/init.sh printf fallback to ${NEW_VER}"
  tmp="$(mktemp lib.init.fallback.tmp.XXXXXX)"
  awk -v new="$NEW_VER" '
    BEGIN { replaced = 0 }
    {
      if (!replaced && $0 ~ /printf[[:space:]]+'\''%s'\''[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/) {
        sub(/printf[[:space:]]+'\''%s'\''[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/, "printf '\''%s'\'' \"" new "\"")
        replaced = 1
      }
      print
    }
    END { if (replaced==0) exit 2 }
  ' lib/init.sh > "$tmp" 2>/dev/null || awk_exit=$? || true

  if [ "${awk_exit:-0}" -eq 0 ]; then
    mv "$tmp" lib/init.sh
  else
    rm -f "$tmp"
    echo "==> No printf fallback found; inserting conservative VER fallback near top"
    tmp="$(mktemp lib.init.insert.tmp.XXXXXX)"
    awk -v v="$NEW_VER" 'NR==1{print; print "# (Inserted VER fallback)"; print "VER=\"'"$NEW_VER"'\""; next}1' lib/init.sh > "$tmp" && mv "$tmp" lib/init.sh
  fi

  # 3c: validate syntax; roll back on failure
  if ! bash -n lib/init.sh; then
    echo "ERROR: lib/init.sh has syntax errors after edit; restoring backup"
    mv lib/init.sh.bak lib/init.sh
    rm -f lib/init.sh.bak
    exit 1
  fi

  rm -f lib/init.sh.bak || true
  git add lib/init.sh
else
  echo "==> lib/init.sh not found; skipping init version update"
fi

# Step 4: promote [Unreleased] in docs/CHANGELOG.md and reinsert a fresh one
DATE="$(date +"%Y-%m-%d")"
CHANGELOG_PATH="docs/CHANGELOG.md"

if [ -f "$CHANGELOG_PATH" ]; then
  echo "==> Promoting [Unreleased] to v${NEW_VER} and reinserting [Unreleased]"
  tmp="$(mktemp changelog.tmp.XXXXXX)"
  # Print a fresh Unreleased header at the top, then when we encounter the first
  # existing "## [Unreleased]" header in the file, promote it to the release header
  # and continue printing the original Unreleased content under the new release.
  awk -v ver="$NEW_VER" -v date="$DATE" '
    BEGIN {
      promoted = 0
      # Insert a fresh Unreleased header at the top of the file
      print "## [Unreleased]"
      print ""
    }
    {
      if (!promoted && $0 ~ /^## 

\[Unreleased\]

/) {
        # Skip the original Unreleased header and insert the promoted release header
        print "## v" ver " - " date
        promoted = 1
        next
      }
      print
    }
    END {
      # If no Unreleased header was found, append a release header at the end
      if (!promoted) {
        print ""
        print "## v" ver " - " date
      }
    }
  ' "$CHANGELOG_PATH" > "$tmp" && mv "$tmp" "$CHANGELOG_PATH"
else
  echo "==> No CHANGELOG.md found; creating docs/CHANGELOG.md with Unreleased and release entries"
  mkdir -p "$(dirname "$CHANGELOG_PATH")"
  tmp="$(mktemp changelog.tmp.XXXXXX)"
  {
    echo "## [Unreleased]"
    echo ""
    echo "## v${NEW_VER} - ${DATE}"
    echo ""
    git log --pretty=format:"* %s" --no-merges
    echo ""
  } > "$tmp"
  mv "$tmp" "$CHANGELOG_PATH"
fi
git add "$CHANGELOG_PATH"

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

# Create annotated tag for the release (handle local and remote conflicts)
if git rev-parse "refs/tags/v${NEW_VER}" >/dev/null 2>&1; then
  git tag -d "v${NEW_VER}" || true
fi
git tag -a "v${NEW_VER}" -m "Release v${NEW_VER}"

# Step 6.5: determine branch to push from (handle detached HEAD)
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD || true)"
if [ "$CURRENT_BRANCH" = "HEAD" ] || [ -z "$CURRENT_BRANCH" ]; then
  RELEASE_BRANCH="release/v${NEW_VER}"
  echo "==> Detached HEAD detected; creating branch ${RELEASE_BRANCH} from current commit"
  git checkout -b "${RELEASE_BRANCH}"
  CURRENT_BRANCH="${RELEASE_BRANCH}"
fi

# Step 7: push commit and tag to origin with safety for existing remote tag
echo "==> Pushing commit and tag to origin (branch: ${CURRENT_BRANCH})"

# If remote tag exists, require FORCE_TAG_UPDATE=1 to overwrite
if git ls-remote --tags origin "refs/tags/v${NEW_VER}" | grep -q "refs/tags/v${NEW_VER}"; then
  if [ "${FORCE_TAG_UPDATE:-0}" = "1" ]; then
    echo "==> Remote tag exists; deleting remote tag (FORCE_TAG_UPDATE=1)"
    git push --delete origin "v${NEW_VER}" || true
  else
    echo "ERROR: remote tag v${NEW_VER} already exists; set FORCE_TAG_UPDATE=1 to overwrite"
    exit 1
  fi
fi

git push origin "${CURRENT_BRANCH}"
git push origin "v${NEW_VER}"

# Step 8: generate grouped changelog notes for GitHub release
echo "==> Generating grouped changelog notes"
CHANGELOG=""
add_section() {
  local type="$1"
  local title="$2"
  local entries
  entries="$(git log "${LAST_TAG}"..HEAD --grep="^${type}" --pretty=format:"* %s" --no-merges || true)"
  if [ -n "$entries" ]; then
    CHANGELOG="${CHANGELOG}\n### ${title}\n${entries}\n"
  fi
}

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -z "$LAST_TAG" ]; then
  LAST_TAG="$(git rev-list --max-parents=0 HEAD)"
fi

add_section "feat:" "Features"
add_section "fix:" "Fixes"
add_section "docs:" "Documentation"
add_section "chore:" "Chores"
add_section "refactor:" "Refactoring"
add_section "test:" "Tests"

if [ -z "$CHANGELOG" ]; then
  CHANGELOG="$(git log "${LAST_TAG}"..HEAD --pretty=format:"* %s" --no-merges)"
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

  # Escape double quotes in notes
  NOTES="$(printf "%b" "$CHANGELOG" | sed 's/"/\\"/g')"
  PRERELEASE_JSON=false
  DRAFT_JSON=false
  if [ -n "$PRERELEASE_FLAG" ]; then PRERELEASE_JSON=true; fi
  if [ -n "$DRAFT_FLAG" ]; then DRAFT_JSON=true; fi

  PAYLOAD=$(cat <<EOF
{
  "tag_name":"v${NEW_VER}",
  "name":"v${NEW_VER}",
  "body":"${NOTES}",
  "draft": ${DRAFT_JSON},
  "prerelease": ${PRERELEASE_JSON}
}
EOF
)

  resp="$(mktemp)"
  HTTP_STATUS="$(curl -s -o "$resp" -w "%{http_code}" -X POST "https://api.github.com/repos/${REPO}/releases" \
    -H "Authorization: token ${GHTOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")"

  if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
    echo "==> GitHub release created successfully"
    if [ -f "dist/checksums-${NEW_VER}.tar.gz" ]; then
      if command -v jq >/dev/null 2>&1; then
        UPLOAD_URL="$(jq -r '.upload_url // empty' "$resp" | sed -e 's/{?name,label}//')"
      else
        UPLOAD_URL="$(sed -n 's/.*"upload_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$resp" | sed -e 's/{?name,label}//')"
      fi

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
    echo "==> GitHub release creation failed (status: $HTTP_STATUS); response saved to $resp"
    echo "Response preview:"
    head -n 200 "$resp" || true
  fi
  rm -f "$resp"
else
  echo "==> No GH_TOKEN/GITHUB_TOKEN provided; skipping API release step"
  echo "Changelog for v${NEW_VER}:"
  printf "%b\n" "$CHANGELOG"
fi

echo "✅ Release ${NEW_VER} complete"
