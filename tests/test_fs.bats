#!/usr/bin/env bats
load '../lib/fs.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  LOG_BASE="#####checksums#####"
  ALT_LOG_EXCL="#####checksums#####"
  LOCK_SUFFIX=".lock"
}

teardown() { rm -rf "$TMPDIR"; }

@test "has_files returns 0 when user file exists" {
  # Create a file that is not excluded by tool filename patterns
  echo "data" > "$TMPDIR/user.txt"
  run has_files "$TMPDIR"
  echo "status=$status output=$output"
  [ "$status" -eq 0 ]
}

@test "has_files returns 1 when only tool files exist" {
  touch "$TMPDIR/#####checksums#####.md5"
  run has_files "$TMPDIR"
  [ "$status" -eq 1 ]
}

@test "has_local_files distinguishes container-only dirs" {
  mkdir "$TMPDIR/parent"
  mkdir "$TMPDIR/parent/sub"
  echo "data" > "$TMPDIR/parent/sub/file.txt"
  run has_local_files "$TMPDIR/parent"
  [ "$status" -eq 1 ]
}

@test "count_files counts candidate files" {
  echo "foo" > "$TMPDIR/foo.txt"
  echo "bar" > "$TMPDIR/bar.txt"
  result=$(count_files "$TMPDIR")
  [ "$result" -eq 2 ]
}
