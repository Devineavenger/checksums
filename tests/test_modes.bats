#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/process.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  SUM_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  TARGET_DIR="$TMPDIR"
}
teardown() { rm -rf "$TMPDIR"; }

@test "process_single_directory in verify-only mode does not write sidecars" {
  VERIFY_ONLY=1
  echo "hello" > "$TMPDIR/data.txt"
  run process_single_directory "$TMPDIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TMPDIR/$SUM_FILENAME" ]
  [ ! -f "$TMPDIR/$META_FILENAME" ]
}

@test "process_single_directory in dry-run mode does not write sidecars" {
  DRY_RUN=1
  echo "hello" > "$TMPDIR/data.txt"
  run process_single_directory "$TMPDIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TMPDIR/$SUM_FILENAME" ]
  [ ! -f "$TMPDIR/$META_FILENAME" ]
  [ ! -f "$TMPDIR/$LOG_FILENAME" ]
}

@test "process_single_directory respects NO_ROOT_SIDEFILES" {
  NO_ROOT_SIDEFILES=1
  echo "hello" > "$TMPDIR/data.txt"
  run process_single_directory "$TMPDIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TMPDIR/$SUM_FILENAME" ]
}
