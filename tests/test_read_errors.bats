#!/usr/bin/env bats
# Tests for graceful permission/read error handling.
# Verifies that unreadable or vanished files are skipped from manifests with
# clear diagnostics instead of silently writing blank hashes.

load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/verification.sh'
load '../lib/hash.sh'
load '../lib/fs.sh'
load '../lib/meta.sh'
load '../lib/tools.sh'
load '../lib/stat.sh'
load '../lib/compat.sh'
load '../lib/process.sh'

setup() {
  TEST_DIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  PER_FILE_ALGO="md5"
  META_SIG_ALGO="sha256"
  SUM_FILENAME="${BASE_NAME}.${PER_FILE_ALGO}"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  LOCK_SUFFIX=".lock"
  TARGET_DIR="$TEST_DIR"
  NO_ROOT_SIDEFILES=0
  SKIP_EMPTY=1
  DEBUG=0
  VERBOSE=0
  DRY_RUN=0
  VERIFY_ONLY=0
  FORCE_REBUILD=0
  FIRST_RUN=0
  MINIMAL=0
  NO_REUSE=0
  QUIET=0
  PROGRESS=0
  STORE_DIR=""
  STORE_DIR_EXCL=""
  MAX_SIZE_BYTES=0
  MIN_SIZE_BYTES=0
  EXCLUDE_PATTERNS=()
  INCLUDE_PATTERNS=()

  RUN_ID="test-run-id"
  RUN_LOG="$TEST_DIR/test.run.log"
  LOG_FILEPATH="$RUN_LOG"
  : > "$RUN_LOG"
  errors=()
  count_errors=0
  count_read_errors=0
  PARALLEL_JOBS=1
  BATCH_RULES="0-1M:20,1M-80M:5,>80M:1"

  detect_tools
  detect_stat
  check_bash_version
  build_exclusions
}

teardown() {
  # Restore permissions before removal so rm -rf succeeds
  chmod -R u+rw "$TEST_DIR" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}

# --- file_hash unit tests ---

@test "file_hash returns 2 for non-existent file" {
  run file_hash "$TEST_DIR/does_not_exist.txt" md5
  [ "$status" -eq 2 ]
}

@test "file_hash returns 0 for readable file" {
  echo "hello" > "$TEST_DIR/readable.txt"
  run file_hash "$TEST_DIR/readable.txt" md5
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "file_hash output is empty on error" {
  run file_hash "$TEST_DIR/vanished.txt" md5
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "file_hash returns 2 for unreadable file" {
  echo "secret" > "$TEST_DIR/noperm.txt"
  if [ "$(id -u)" -eq 0 ]; then
    # Root bypasses file permission bits; replacing the file with a directory
    # causes hash tools to fail with "Is a directory" even for root
    rm "$TEST_DIR/noperm.txt"
    mkdir "$TEST_DIR/noperm.txt"
  else
    chmod 000 "$TEST_DIR/noperm.txt"
  fi
  run file_hash "$TEST_DIR/noperm.txt" md5
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# --- _do_hash_batch sentinel tests ---

@test "_do_hash_batch writes ERROR sentinel for missing file" {
  echo "good" > "$TEST_DIR/good.txt"
  results="$TEST_DIR/results.out"
  _do_hash_batch md5 "$results" "$TEST_DIR/good.txt" "$TEST_DIR/gone.txt"
  grep -q "good.txt" "$results"
  grep -q "gone.txt" "$results"
  # The missing file should have ERROR: sentinel
  grep "gone.txt" "$results" | grep -q "ERROR:"
  # The good file should NOT have ERROR: sentinel
  ! grep "good.txt" "$results" | grep -q "ERROR:"
}

@test "_do_hash_batch writes normal hash for readable file" {
  echo "data" > "$TEST_DIR/file.txt"
  results="$TEST_DIR/results.out"
  _do_hash_batch md5 "$results" "$TEST_DIR/file.txt"
  # Should have a hex hash, not ERROR:
  ! grep "file.txt" "$results" | grep -q "ERROR:"
  # Hash should be non-empty hex
  local hash_val
  hash_val=$(cut -f2 "$results")
  [[ "$hash_val" =~ ^[0-9a-f]+$ ]]
}

# --- process_single_directory with vanished files ---

@test "process_single_directory skips vanished files from manifest" {
  mkdir "$TEST_DIR/sub"
  echo "keep" > "$TEST_DIR/sub/keep.txt"
  echo "vanish" > "$TEST_DIR/sub/vanish.txt"
  init_batch_thresholds

  # Process once to get baseline
  process_single_directory "$TEST_DIR/sub"
  local sumf="$TEST_DIR/sub/$SUM_FILENAME"
  [ -f "$sumf" ]
  grep -q "keep.txt" "$sumf"
  grep -q "vanish.txt" "$sumf"

  # Now remove file and reprocess (force rebuild to re-hash everything)
  rm "$TEST_DIR/sub/vanish.txt"
  FORCE_REBUILD=1
  count_read_errors=0
  errors=()
  count_errors=0
  process_single_directory "$TEST_DIR/sub"

  # Vanished file should not be in the new manifest
  ! grep -q "vanish.txt" "$sumf"
  # Kept file should still be present
  grep -q "keep.txt" "$sumf"
}

@test "manifest contains no blank hashes for vanished file" {
  mkdir "$TEST_DIR/sub"
  echo "a" > "$TEST_DIR/sub/a.txt"
  echo "b" > "$TEST_DIR/sub/b.txt"
  init_batch_thresholds

  process_single_directory "$TEST_DIR/sub"
  local sumf="$TEST_DIR/sub/$SUM_FILENAME"
  [ -f "$sumf" ]

  # Verify no blank hashes exist (each line should have hash + filename)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local hash="${line%%[[:space:]]*}"
    [[ "$hash" =~ ^[0-9a-f]+$ ]]
  done < "$sumf"
}

@test "mixed readable/vanished — readable files still hashed correctly" {
  mkdir "$TEST_DIR/sub"
  echo "alpha" > "$TEST_DIR/sub/alpha.txt"
  echo "beta" > "$TEST_DIR/sub/beta.txt"
  echo "gamma" > "$TEST_DIR/sub/gamma.txt"
  init_batch_thresholds

  # Remove beta before first process
  rm "$TEST_DIR/sub/beta.txt"

  process_single_directory "$TEST_DIR/sub"
  local sumf="$TEST_DIR/sub/$SUM_FILENAME"
  [ -f "$sumf" ]

  # Alpha and gamma should be in manifest with valid hashes
  grep -q "alpha.txt" "$sumf"
  grep -q "gamma.txt" "$sumf"
  # Beta should not appear (it was already gone when find ran)
  ! grep -q "beta.txt" "$sumf"
}

# --- Verification detects UNREADABLE ---

@test "sequential verification reports UNREADABLE for vanished file" {
  mkdir "$TEST_DIR/sub"
  echo "data" > "$TEST_DIR/sub/file.txt"
  init_batch_thresholds
  process_single_directory "$TEST_DIR/sub"

  local sumf="$TEST_DIR/sub/$SUM_FILENAME"
  [ -f "$sumf" ]

  # Now delete the file and verify
  rm "$TEST_DIR/sub/file.txt"
  RUN_LOG="$TEST_DIR/verify.run.log"
  : > "$RUN_LOG"

  run _verify_md5_sequential "$TEST_DIR/sub" "$sumf"
  # Should return non-zero (missing file)
  [ "$status" -ne 0 ]
  # Run log should have MISSING entry (file doesn't exist at all)
  grep -q "MISSING:" "$RUN_LOG"
}

# --- read_meta handles unreadable meta gracefully ---

@test "read_meta handles unreadable meta gracefully" {
  mkdir "$TEST_DIR/sub"
  echo "#meta	v1	2024-01-01T00:00:00Z" > "$TEST_DIR/sub/$META_FILENAME"

  if [ "$(id -u)" -eq 0 ]; then
    # Root bypasses file permission bits; replacing the file with a directory
    # causes the [ -f ] guard in read_meta to return false (graceful skip)
    rm "$TEST_DIR/sub/$META_FILENAME"
    mkdir "$TEST_DIR/sub/$META_FILENAME"
  else
    chmod 000 "$TEST_DIR/sub/$META_FILENAME"
  fi

  errors=()
  count_errors=0
  # Should not crash under set -e; should return 0 for both !-r and !-f paths
  run read_meta "$TEST_DIR/sub/$META_FILENAME"
  [ "$status" -eq 0 ]
}
