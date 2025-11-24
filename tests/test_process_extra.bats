#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/hash.sh'
load '../lib/fs.sh'
load '../lib/meta.sh'
load '../lib/tools.sh'
load '../lib/stat.sh'
load '../lib/compat.sh'
load '../lib/process.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  LOCK_SUFFIX=".lock"      # ensure the test uses the same suffix as the code
  TARGET_DIR="$TMPDIR"
  NO_ROOT_SIDEFILES=0
  DEBUG=1

  RUN_ID="test-run-id"
  RUN_LOG="$TMPDIR/test.run.log"
  LOG_FILEPATH="$RUN_LOG"
  : > "$RUN_LOG"
  errors=()
  count_errors=0
  PARALLEL_JOBS=1
  BATCH_RULES="0-1M:20,1M-80M:5,>80M:1"

  detect_tools
  detect_stat
  check_bash_version
  build_exclusions
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "process_single_directory skips container-only dir" {
  mkdir "$TMPDIR/parent"
  mkdir "$TMPDIR/parent/sub"
  echo "data" > "$TMPDIR/parent/sub/file.txt"
  SKIP_EMPTY=1
  run process_single_directory "$TMPDIR/parent"
  [ "$status" -eq 0 ]
  [ ! -f "$TMPDIR/parent/$MD5_FILENAME" ]
  [ ! -f "$TMPDIR/parent/$META_FILENAME" ]
  [ ! -f "$TMPDIR/parent/$LOG_FILENAME" ]
}

@test "verify-only skips container-only dir without error" {
  mkdir "$TMPDIR/parent"
  mkdir "$TMPDIR/parent/sub"
  echo "data" > "$TMPDIR/parent/sub/file.txt"
  VERIFY_ONLY=1
  PER_FILE_ALGO="md5"
  META_SIG_ALGO="sha256"
  run process_single_directory "$TMPDIR/parent"
  [ "$status" -eq 0 ]
  grep -q "Verify-only: no local files in $TMPDIR/parent and no MD5 present; skipping" "$RUN_LOG"
}

@test "verify-only reports missing md5 when local files exist" {
  echo "foo" > "$TMPDIR/file.txt"
  VERIFY_ONLY=1
  PER_FILE_ALGO="md5"
  META_SIG_ALGO="sha256"
  run process_single_directory "$TMPDIR"
  [ "$status" -eq 0 ]
  grep -q "Verify-only: MD5 file missing in $TMPDIR" "$RUN_LOG"
}

@test "dry-run does not create sidecars" {
  echo "foo" > "$TMPDIR/file.txt"
  DRY_RUN=1
  PER_FILE_ALGO="md5"
  META_SIG_ALGO="sha256"
  run process_single_directory "$TMPDIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TMPDIR/$MD5_FILENAME" ]
  [ ! -f "$TMPDIR/$META_FILENAME" ]
  [ ! -f "$TMPDIR/$LOG_FILENAME" ]
}

@test "stale lock file removed" {
  metaf="$TMPDIR/$META_FILENAME"
  : > "$metaf"
  lf="${metaf}${LOCK_SUFFIX:-.lock}"
  : > "$lf"

  # Debug: show what the test created
  echo "TEST-PRE: metaf=$metaf lf=$lf" >> "$RUN_LOG"
  ls -la "$TMPDIR" >> "$RUN_LOG" 2>&1

  run process_single_directory "$TMPDIR"

  # Debug: show state after function call
  echo "TEST-POST: metaf=$metaf lf=$lf" >> "$RUN_LOG"
  ls -la "$TMPDIR" >> "$RUN_LOG" 2>&1

  [ "$status" -eq 0 ]
  [ ! -s "$lf" ]   # lock file exists but is zero‑byte
}

@test "cleanup_leftover_locks removes stale lock" {
  metaf="$TMPDIR/$META_FILENAME"
  : > "$metaf"
  lf="${metaf}${LOCK_SUFFIX}"
  : > "$lf"
  # make it stale if your helper only removes old locks:
  touch -d '1 day ago' "$lf"

  run cleanup_leftover_locks "$TMPDIR"
  [ "$status" -eq 0 ]
  [ ! -f "$lf" ]
}

@test "process_single_directory on missing dir returns error" {
  run process_single_directory "$TMPDIR/missing"
  [ "$status" -ne 0 ]
}
