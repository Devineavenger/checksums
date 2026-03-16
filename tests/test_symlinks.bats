#!/usr/bin/env bats
# tests/test_symlinks.bats
#
# Tests for symlink handling flags (-L / --follow-symlinks / --no-follow-symlinks).
#
# Verifies:
#  - Default behavior: symlinked files and directories are not followed
#  - -L / --follow-symlinks: symlinked files appear in manifests
#  - -L / --follow-symlinks: symlinked directories are descended into
#  - --no-follow-symlinks: explicitly restores default (last flag wins)
#  - Broken symlinks are silently skipped with -L
#  - Config file: FOLLOW_SYMLINKS=1 works
#  - Status mode respects -L

load test_helper/bats-support/load
load test_helper/bats-assert/load

setup() {
  CHECKSUMS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/checksums.sh"
  chmod +x "$CHECKSUMS" 2>/dev/null || true
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chk_symlink.XXXXXX")"

  # Create a real directory with a real file
  mkdir -p "$TEST_DIR/data/realdir"
  echo "real content" > "$TEST_DIR/data/realdir/realfile.txt"
}

teardown() {
  [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR" 2>/dev/null || true
}

# ----------------------------------------------------------------
# Default behavior: symlinks NOT followed
# ----------------------------------------------------------------

@test "default: symlinked files are not included in manifest" {
  # Create a symlink to realfile.txt in a separate directory
  mkdir -p "$TEST_DIR/data/linkdir"
  ln -s "$TEST_DIR/data/realdir/realfile.txt" "$TEST_DIR/data/linkdir/linked.txt"
  # Also add a real file so the directory isn't skipped as empty
  echo "local content" > "$TEST_DIR/data/linkdir/local.txt"

  run bash "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR/data/linkdir"
  assert_success

  # Manifest should contain local.txt but NOT linked.txt (symlink not followed)
  local manifest="$TEST_DIR/data/linkdir/#####checksums#####.md5"
  assert [ -f "$manifest" ]
  run grep -c "local.txt" "$manifest"
  assert_output "1"
  run grep "linked.txt" "$manifest"
  assert_failure
}

@test "default: symlinked directories are not descended" {
  # Create a symlink to realdir from a sibling location
  mkdir -p "$TEST_DIR/data/parent"
  echo "parent file" > "$TEST_DIR/data/parent/parentfile.txt"
  ln -s "$TEST_DIR/data/realdir" "$TEST_DIR/data/parent/symdir"

  run bash "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR/data/parent"
  assert_success

  # Only parentfile.txt should be in the parent manifest
  local manifest="$TEST_DIR/data/parent/#####checksums#####.md5"
  assert [ -f "$manifest" ]
  run grep "parentfile.txt" "$manifest"
  assert_success

  # symdir/realfile.txt should NOT have a manifest (directory not descended)
  assert [ ! -f "$TEST_DIR/data/parent/symdir/#####checksums#####.md5" ]
}

# ----------------------------------------------------------------
# -L / --follow-symlinks: symlinks followed
# ----------------------------------------------------------------

@test "-L: symlinked files are included in manifest" {
  mkdir -p "$TEST_DIR/data/linkdir"
  ln -s "$TEST_DIR/data/realdir/realfile.txt" "$TEST_DIR/data/linkdir/linked.txt"
  echo "local content" > "$TEST_DIR/data/linkdir/local.txt"

  run bash "$CHECKSUMS" -y -L --allow-root-sidefiles "$TEST_DIR/data/linkdir"
  assert_success

  # Both files should appear in the manifest
  local manifest="$TEST_DIR/data/linkdir/#####checksums#####.md5"
  assert [ -f "$manifest" ]
  run grep "local.txt" "$manifest"
  assert_success
  run grep "linked.txt" "$manifest"
  assert_success
}

@test "--follow-symlinks: same as -L" {
  mkdir -p "$TEST_DIR/data/linkdir"
  ln -s "$TEST_DIR/data/realdir/realfile.txt" "$TEST_DIR/data/linkdir/linked.txt"
  echo "local content" > "$TEST_DIR/data/linkdir/local.txt"

  run bash "$CHECKSUMS" -y --follow-symlinks --allow-root-sidefiles "$TEST_DIR/data/linkdir"
  assert_success

  local manifest="$TEST_DIR/data/linkdir/#####checksums#####.md5"
  assert [ -f "$manifest" ]
  run grep "linked.txt" "$manifest"
  assert_success
}

@test "-L: symlinked directories are descended" {
  mkdir -p "$TEST_DIR/data/parent"
  echo "parent file" > "$TEST_DIR/data/parent/parentfile.txt"
  ln -s "$TEST_DIR/data/realdir" "$TEST_DIR/data/parent/symdir"

  run bash "$CHECKSUMS" -y -L "$TEST_DIR/data/parent"
  assert_success

  # The symlinked directory should have been processed — its manifest should exist
  local manifest="$TEST_DIR/data/parent/symdir/#####checksums#####.md5"
  assert [ -f "$manifest" ]
  run grep "realfile.txt" "$manifest"
  assert_success
}

# ----------------------------------------------------------------
# --no-follow-symlinks overrides -L (last flag wins)
# ----------------------------------------------------------------

@test "--no-follow-symlinks overrides earlier -L" {
  mkdir -p "$TEST_DIR/data/linkdir"
  ln -s "$TEST_DIR/data/realdir/realfile.txt" "$TEST_DIR/data/linkdir/linked.txt"
  echo "local content" > "$TEST_DIR/data/linkdir/local.txt"

  run bash "$CHECKSUMS" -y -L --no-follow-symlinks --allow-root-sidefiles "$TEST_DIR/data/linkdir"
  assert_success

  # linked.txt should NOT be in manifest (--no-follow-symlinks won)
  local manifest="$TEST_DIR/data/linkdir/#####checksums#####.md5"
  assert [ -f "$manifest" ]
  run grep "linked.txt" "$manifest"
  assert_failure
}

# ----------------------------------------------------------------
# Broken symlinks
# ----------------------------------------------------------------

@test "-L: broken symlinks are silently skipped" {
  mkdir -p "$TEST_DIR/data/brokendir"
  echo "good file" > "$TEST_DIR/data/brokendir/good.txt"
  ln -s "$TEST_DIR/nonexistent_target" "$TEST_DIR/data/brokendir/broken.txt"

  run bash "$CHECKSUMS" -y -L --allow-root-sidefiles "$TEST_DIR/data/brokendir"
  assert_success

  # Only good.txt should be in manifest; broken symlink silently skipped
  local manifest="$TEST_DIR/data/brokendir/#####checksums#####.md5"
  assert [ -f "$manifest" ]
  run grep "good.txt" "$manifest"
  assert_success
  run grep "broken.txt" "$manifest"
  assert_failure
}

# ----------------------------------------------------------------
# Config file support
# ----------------------------------------------------------------

@test "config: FOLLOW_SYMLINKS=1 enables symlink following" {
  mkdir -p "$TEST_DIR/data/linkdir"
  ln -s "$TEST_DIR/data/realdir/realfile.txt" "$TEST_DIR/data/linkdir/linked.txt"
  echo "local content" > "$TEST_DIR/data/linkdir/local.txt"

  # Write config file
  cat > "$TEST_DIR/data/linkdir/#####checksums#####.conf" <<'EOF'
FOLLOW_SYMLINKS=1
EOF

  run bash "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR/data/linkdir"
  assert_success

  local manifest="$TEST_DIR/data/linkdir/#####checksums#####.md5"
  assert [ -f "$manifest" ]
  run grep "linked.txt" "$manifest"
  assert_success
}

# ----------------------------------------------------------------
# Status mode with -L
# ----------------------------------------------------------------

@test "status mode: -L includes symlinked files" {
  mkdir -p "$TEST_DIR/data/parent"
  echo "parent file" > "$TEST_DIR/data/parent/parentfile.txt"
  ln -s "$TEST_DIR/data/realdir" "$TEST_DIR/data/parent/symdir"

  # First run with -L to create manifests including symlinked dir
  run bash "$CHECKSUMS" -y -L "$TEST_DIR/data/parent"
  assert_success

  # Status mode with -L should see the symlinked directory
  run bash "$CHECKSUMS" -S -L "$TEST_DIR/data/parent"
  # Should succeed (no changes)
  assert_success
}

# ----------------------------------------------------------------
# Verify-only mode with -L
# ----------------------------------------------------------------

@test "verify-only mode: -L includes symlinked files" {
  mkdir -p "$TEST_DIR/data/linkdir"
  ln -s "$TEST_DIR/data/realdir/realfile.txt" "$TEST_DIR/data/linkdir/linked.txt"
  echo "local content" > "$TEST_DIR/data/linkdir/local.txt"

  # First run with -L to create manifests
  run bash "$CHECKSUMS" -y -L --allow-root-sidefiles "$TEST_DIR/data/linkdir"
  assert_success

  # Verify-only with -L should pass (files unchanged)
  run bash "$CHECKSUMS" -V -y -L --allow-root-sidefiles "$TEST_DIR/data/linkdir"
  assert_success
}
