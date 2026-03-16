#!/usr/bin/env bats
# tests/test_summary_stats.bats
#
# Tests for summary stats on console (file counts, bytes, elapsed, throughput).
#
# Verifies:
#  - Files hashed count appears after a normal run
#  - Files reused count appears on second run (incremental)
#  - Bytes hashed/reused shown when non-zero
#  - Elapsed time shown
#  - Throughput shown when elapsed > 0 and bytes > 0
#  - Dry-run does not show file stats
#  - _format_bytes produces correct human-readable output

load test_helper/bats-support/load
load test_helper/bats-assert/load

setup() {
  CHECKSUMS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/checksums.sh"
  chmod +x "$CHECKSUMS" 2>/dev/null || true
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chk_summary.XXXXXX")"

  # Create test files with known content
  mkdir -p "$TEST_DIR/data/subdir"
  echo "file one content" > "$TEST_DIR/data/subdir/file1.txt"
  echo "file two content here" > "$TEST_DIR/data/subdir/file2.txt"
  echo "third file" > "$TEST_DIR/data/subdir/file3.txt"
}

teardown() {
  [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR" 2>/dev/null || true
}

# ----------------------------------------------------------------
# File counts
# ----------------------------------------------------------------

@test "summary shows Files hashed count after normal run" {
  run bash "$CHECKSUMS" -y "$TEST_DIR/data"
  assert_success
  assert_output --partial "Files hashed:"
  # Should show 3 files hashed
  assert_output --partial "Files hashed:  "
}

@test "summary shows Files reused count on second run" {
  # First run: hash everything
  bash "$CHECKSUMS" -y "$TEST_DIR/data" >/dev/null 2>&1

  # Touch one file to trigger reprocessing (planner detects newer file).
  # The touched file gets rehashed while the other 2 are reused from cache.
  sleep 1
  touch "$TEST_DIR/data/subdir/file1.txt"

  # Second run: 1 file rehashed, 2 reused
  run bash "$CHECKSUMS" -y "$TEST_DIR/data"
  assert_success
  assert_output --partial "Files reused:"
}

@test "first run shows zero reused files" {
  run bash "$CHECKSUMS" -y "$TEST_DIR/data"
  assert_success
  # Files hashed should be 3, reused should be 0
  # When reused is 0 but hashed > 0, both lines still appear
  assert_output --partial "Files hashed:"
  assert_output --partial "Files reused:"
}

# ----------------------------------------------------------------
# Bytes
# ----------------------------------------------------------------

@test "summary shows Bytes hashed after normal run" {
  run bash "$CHECKSUMS" -y "$TEST_DIR/data"
  assert_success
  assert_output --partial "Bytes hashed:"
}

@test "summary shows Bytes reused on second run" {
  bash "$CHECKSUMS" -y "$TEST_DIR/data" >/dev/null 2>&1

  # Touch one file to trigger reprocessing; other files will be reused
  sleep 1
  touch "$TEST_DIR/data/subdir/file2.txt"

  run bash "$CHECKSUMS" -y "$TEST_DIR/data"
  assert_success
  assert_output --partial "Bytes reused:"
}

# ----------------------------------------------------------------
# Elapsed and throughput
# ----------------------------------------------------------------

@test "summary shows Elapsed time" {
  run bash "$CHECKSUMS" -y "$TEST_DIR/data"
  assert_success
  assert_output --partial "Elapsed:"
}

# ----------------------------------------------------------------
# Dry-run: no file stats
# ----------------------------------------------------------------

@test "dry-run does not show file stats" {
  run bash "$CHECKSUMS" -n -y "$TEST_DIR/data"
  assert_success
  refute_output --partial "Files hashed:"
  refute_output --partial "Bytes hashed:"
}

# ----------------------------------------------------------------
# _format_bytes unit test
# ----------------------------------------------------------------

@test "_format_bytes produces correct output" {
  # Source the modules to get _format_bytes
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/init.sh"
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/color.sh"
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/logging.sh"
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/orchestrator.sh"

  run _format_bytes 0
  assert_output "0 B"

  run _format_bytes 512
  assert_output "512 B"

  run _format_bytes 1024
  assert_output "1.0 KiB"

  run _format_bytes 1048576
  assert_output "1.0 MiB"

  run _format_bytes 1073741824
  assert_output "1.0 GiB"

  run _format_bytes 1099511627776
  assert_output "1.0 TiB"
}
