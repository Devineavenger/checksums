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
  SUM_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  TARGET_DIR="$TMPDIR"
  NO_ROOT_SIDEFILES=0

  # Initialise run‑level globals
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

@test "process_single_directory creates sidecar files" {
  PER_FILE_ALGO="md5"
  META_SIG_ALGO="sha256"
  echo "hello world" > "$TMPDIR/data.txt"
  echo "TOOL_md5_cmd=$TOOL_md5_cmd"  # debug
  run process_single_directory "$TMPDIR"
  echo "status=$status output=$output"  # debug
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/$SUM_FILENAME" ]
  [ -f "$TMPDIR/$META_FILENAME" ]
  [ -f "$TMPDIR/$LOG_FILENAME" ]
}

@test "process_single_directory skips empty dir when SKIP_EMPTY=1" {
  mkdir "$TMPDIR/empty"
  SKIP_EMPTY=1
  VERIFY_ONLY=0
  DRY_RUN=0
  run process_single_directory "$TMPDIR/empty"
  [ "$status" -eq 0 ]
  [ ! -f "$TMPDIR/empty/$SUM_FILENAME" ]
  [ ! -f "$TMPDIR/empty/$META_FILENAME" ]
  [ ! -f "$TMPDIR/empty/$LOG_FILENAME" ]
}
