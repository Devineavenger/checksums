#!/usr/bin/env bats

# Load the helper functions directly
load '../lib/hash.sh'
load '../lib/first_run.sh'

setup() {
  TMPDIR=$(mktemp -d)
  echo "hello world" > "$TMPDIR/file.txt"
  BASE_NAME="#####checksums#####"
  SUM_FILENAME="${BASE_NAME}.md5"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "verify_md5_file returns 2 for missing checksum file" {
  rm -f "$TMPDIR/$SUM_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 2 ]
}

@test "verify_md5_file handles multiple files correctly" {
  echo "foo" > "$TMPDIR/foo.txt"
  echo "bar" > "$TMPDIR/bar.txt"
  md5foo=$(file_hash "$TMPDIR/foo.txt" md5)
  md5bar=$(file_hash "$TMPDIR/bar.txt" md5)
  {
    printf '%s  %s\n' "$md5foo" "foo.txt"
    printf '%s  %s\n' "$md5bar" "bar.txt"
  } > "$TMPDIR/$SUM_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 0 ]
}
