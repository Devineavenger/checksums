#!/usr/bin/env bats
load '../lib/first_run.sh'
load '../lib/hash.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  MD5_FILENAME="${BASE_NAME}.md5"
  echo "hello world" > "$TMPDIR/file.txt"
}

teardown() { rm -rf "$TMPDIR"; }

@test "verify_md5_file returns 0 for valid file (GNU format)" {
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  printf '%s  %s\n' "$md5" "file.txt" > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 0 ]
}

@test "verify_md5_file returns 1 for mismatch" {
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  printf '%s  %s\n' "$md5" "file.txt" > "$TMPDIR/$MD5_FILENAME"
  echo "different" > "$TMPDIR/file.txt"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 1 ]
}

@test "verify_md5_file returns 2 for missing file entry" {
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  printf '%s  %s\n' "$md5" "ghost.txt" > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 2 ]
}

@test "verify_md5_file handles BSD/macOS format" {
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  printf 'MD5 (%s) = %s\n' "file.txt" "$md5" > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 0 ]
}
