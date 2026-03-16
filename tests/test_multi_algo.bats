#!/usr/bin/env bats
# tests/test_multi_algo.bats
#
# Tests for multi-algorithm single pass (-a md5,sha256).
#
# Verifies:
#  - Two-algo mode creates both .md5 and .sha256 manifests
#  - Each manifest has correct hash format (verified against individual tools)
#  - .meta stores primary (first) algo hash only
#  - Single algo (-a md5) backward compatible
#  - Invalid algo in comma list rejected
#  - Multi-algo + --check rejected
#  - Multi-algo + --status rejected
#  - Multi-algo + --verify-only rejected
#  - Three algos produce correct manifests
#  - Config file PER_FILE_ALGO=md5,sha256 works
#  - All manifest filenames excluded from scanning
#  - Dry-run mentions all algos
#  - Planner schedules directory if any manifest missing

load test_helper/bats-support/load
load test_helper/bats-assert/load

setup() {
  CHECKSUMS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/checksums.sh"
  chmod +x "$CHECKSUMS" 2>/dev/null || true
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chk_multi.XXXXXX")"

  # Create a directory with test files
  mkdir -p "$TEST_DIR/data"
  echo "hello world" > "$TEST_DIR/data/file1.txt"
  echo "foo bar"     > "$TEST_DIR/data/file2.txt"
}

teardown() {
  [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR" 2>/dev/null || true
}

# Helper: get the expected md5 hash for a file
_expected_md5() {
  md5sum "$1" | cut -d' ' -f1
}

# Helper: get the expected sha256 hash for a file
_expected_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

# ----------------------------------------------------------------
# Basic multi-algo functionality
# ----------------------------------------------------------------

@test "multi-algo: -a md5,sha256 creates both .md5 and .sha256 manifests" {
  run bash "$CHECKSUMS" -a md5,sha256 -y --allow-root-sidefiles "$TEST_DIR/data"
  assert_success
  [ -f "$TEST_DIR/data/#####checksums#####.md5" ]
  [ -f "$TEST_DIR/data/#####checksums#####.sha256" ]
}

@test "multi-algo: .md5 manifest contains correct md5 hashes" {
  bash "$CHECKSUMS" -a md5,sha256 -y --allow-root-sidefiles "$TEST_DIR/data"
  local expected1 expected2
  expected1=$(_expected_md5 "$TEST_DIR/data/file1.txt")
  expected2=$(_expected_md5 "$TEST_DIR/data/file2.txt")
  run grep "file1.txt" "$TEST_DIR/data/#####checksums#####.md5"
  assert_output --partial "$expected1"
  run grep "file2.txt" "$TEST_DIR/data/#####checksums#####.md5"
  assert_output --partial "$expected2"
}

@test "multi-algo: .sha256 manifest contains correct sha256 hashes" {
  bash "$CHECKSUMS" -a md5,sha256 -y --allow-root-sidefiles "$TEST_DIR/data"
  local expected1 expected2
  expected1=$(_expected_sha256 "$TEST_DIR/data/file1.txt")
  expected2=$(_expected_sha256 "$TEST_DIR/data/file2.txt")
  run grep "file1.txt" "$TEST_DIR/data/#####checksums#####.sha256"
  assert_output --partial "$expected1"
  run grep "file2.txt" "$TEST_DIR/data/#####checksums#####.sha256"
  assert_output --partial "$expected2"
}

@test "multi-algo: .meta stores primary (first) algo hash only" {
  bash "$CHECKSUMS" -a md5,sha256 -y --allow-root-sidefiles "$TEST_DIR/data"
  local expected_md5
  expected_md5=$(_expected_md5 "$TEST_DIR/data/file1.txt")
  # .meta should contain the md5 hash (primary), not sha256
  run grep "file1.txt" "$TEST_DIR/data/#####checksums#####.meta"
  assert_output --partial "$expected_md5"
}

@test "multi-algo: single algo (-a sha256) still works (backward compatible)" {
  run bash "$CHECKSUMS" -a sha256 -y --allow-root-sidefiles "$TEST_DIR/data"
  assert_success
  [ -f "$TEST_DIR/data/#####checksums#####.sha256" ]
  # Should NOT create .md5
  [ ! -f "$TEST_DIR/data/#####checksums#####.md5" ]
}

@test "multi-algo: default (-a md5) still works (backward compatible)" {
  run bash "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR/data"
  assert_success
  [ -f "$TEST_DIR/data/#####checksums#####.md5" ]
}

# ----------------------------------------------------------------
# Three algorithms
# ----------------------------------------------------------------

@test "multi-algo: three algos (md5,sha256,sha512) produce all manifests" {
  run bash "$CHECKSUMS" -a md5,sha256,sha512 -y --allow-root-sidefiles "$TEST_DIR/data"
  assert_success
  [ -f "$TEST_DIR/data/#####checksums#####.md5" ]
  [ -f "$TEST_DIR/data/#####checksums#####.sha256" ]
  [ -f "$TEST_DIR/data/#####checksums#####.sha512" ]
}

@test "multi-algo: three algos produce correct hashes in each manifest" {
  bash "$CHECKSUMS" -a md5,sha256,sha512 -y --allow-root-sidefiles "$TEST_DIR/data"

  local expected_md5 expected_sha256 expected_sha512
  expected_md5=$(_expected_md5 "$TEST_DIR/data/file1.txt")
  expected_sha256=$(_expected_sha256 "$TEST_DIR/data/file1.txt")
  expected_sha512=$(sha512sum "$TEST_DIR/data/file1.txt" | cut -d' ' -f1)

  run grep "file1.txt" "$TEST_DIR/data/#####checksums#####.md5"
  assert_output --partial "$expected_md5"
  run grep "file1.txt" "$TEST_DIR/data/#####checksums#####.sha256"
  assert_output --partial "$expected_sha256"
  run grep "file1.txt" "$TEST_DIR/data/#####checksums#####.sha512"
  assert_output --partial "$expected_sha512"
}

# ----------------------------------------------------------------
# Validation / conflict checks
# ----------------------------------------------------------------

@test "multi-algo: invalid algo in comma list rejected" {
  run bash "$CHECKSUMS" -a md5,bogus -y "$TEST_DIR/data"
  assert_failure
  assert_output --partial "Unsupported per-file algo: bogus"
}

@test "multi-algo: + --check rejected" {
  # Create a dummy manifest for --check
  echo "d41d8cd98f00b204e9800998ecf8427e  file1.txt" > "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -a md5,sha256 -c "$TEST_DIR/manifest.md5" "$TEST_DIR/data"
  assert_failure
  assert_output --partial "incompatible with --check"
}

@test "multi-algo: + --status rejected" {
  run bash "$CHECKSUMS" -a md5,sha256 -S "$TEST_DIR/data"
  assert_failure
  assert_output --partial "incompatible with --status"
}

@test "multi-algo: + --verify-only rejected" {
  run bash "$CHECKSUMS" -a md5,sha256 -V "$TEST_DIR/data"
  assert_failure
  assert_output --partial "incompatible with --verify-only"
}

# ----------------------------------------------------------------
# Exclusion and planner behavior
# ----------------------------------------------------------------

@test "multi-algo: manifest files excluded from scanning" {
  bash "$CHECKSUMS" -a md5,sha256 -y --allow-root-sidefiles "$TEST_DIR/data"
  # Run again — manifests should not appear as data files in the manifests
  bash "$CHECKSUMS" -a md5,sha256 -y --allow-root-sidefiles -r "$TEST_DIR/data"
  # Neither manifest should list the other manifest or itself
  run grep "#####checksums#####" "$TEST_DIR/data/#####checksums#####.md5"
  assert_failure  # no match = not listed
}

@test "multi-algo: planner schedules directory if any manifest missing" {
  # Create only .md5, leave .sha256 missing
  bash "$CHECKSUMS" -a md5 -y --allow-root-sidefiles "$TEST_DIR/data"
  [ -f "$TEST_DIR/data/#####checksums#####.md5" ]
  [ ! -f "$TEST_DIR/data/#####checksums#####.sha256" ]
  # Run with multi-algo — should process (sha256 manifest missing)
  run bash "$CHECKSUMS" -a md5,sha256 -y --allow-root-sidefiles "$TEST_DIR/data"
  assert_success
  [ -f "$TEST_DIR/data/#####checksums#####.sha256" ]
}

# ----------------------------------------------------------------
# Dry-run
# ----------------------------------------------------------------

@test "multi-algo: dry-run mentions all algos" {
  run bash "$CHECKSUMS" -a md5,sha256 -n -y --allow-root-sidefiles "$TEST_DIR/data"
  assert_success
  assert_output --partial "md5 sha256"
}

# ----------------------------------------------------------------
# Config file
# ----------------------------------------------------------------

@test "multi-algo: PER_FILE_ALGO=md5,sha256 from config file" {
  cat > "$TEST_DIR/data/#####checksums#####.conf" <<'EOF'
PER_FILE_ALGO=md5,sha256
EOF
  run bash "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR/data"
  assert_success
  [ -f "$TEST_DIR/data/#####checksums#####.md5" ]
  [ -f "$TEST_DIR/data/#####checksums#####.sha256" ]
}

# ----------------------------------------------------------------
# Minimal mode
# ----------------------------------------------------------------

@test "multi-algo: minimal mode writes manifests without .meta" {
  run bash "$CHECKSUMS" -a md5,sha256 -M -y --allow-root-sidefiles "$TEST_DIR/data"
  assert_success
  [ -f "$TEST_DIR/data/#####checksums#####.md5" ]
  [ -f "$TEST_DIR/data/#####checksums#####.sha256" ]
  [ ! -f "$TEST_DIR/data/#####checksums#####.meta" ]
}
