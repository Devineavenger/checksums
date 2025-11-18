#!/usr/bin/env bats

# Load the helper functions directly
load '../lib/hash.sh'
load '../lib/first_run.sh'

setup() {
  TMPDIR=$(mktemp -d)
  echo "hello world" > "$TMPDIR/file.txt"
  BASE_NAME="#####checksums#####"
  MD5_FILENAME="${BASE_NAME}.md5"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "file_hash computes md5 correctly" {
  run file_hash "$TMPDIR/file.txt" md5
  [ "$status" -eq 0 ]
  [ "$output" = "6f5902ac237024bdd0c176cb93063dc4" ]
}

@test "file_hash computes sha256 correctly" {
  run file_hash "$TMPDIR/file.txt" sha256
  [ "$status" -eq 0 ]
  [ "$output" = "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447" ]
}

@test "verify_md5_file returns 0 for valid file (GNU format)" {
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  # GNU md5sum format requires two spaces between hash and filename
  printf '%s  %s\n' "$md5" "file.txt" > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 0 ]
}

@test "verify_md5_file returns 1 for mismatch" {
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  printf '%s  %s\n' "$md5" "file.txt" > "$TMPDIR/$MD5_FILENAME"
  # Corrupt the file
  echo "different content" > "$TMPDIR/file.txt"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 1 ]
}

@test "verify_md5_file returns 2 for missing checksum file" {
  rm -f "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 2 ]
}

@test "verify_md5_file handles BSD/macOS style checksum file" {
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  # BSD/macOS format: MD5 (filename) = hash
  printf 'MD5 (%s) = %s\n' "file.txt" "$md5" > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 0 ]
}

@test "verify_md5_file handles multiple files correctly" {
  echo "foo" > "$TMPDIR/foo.txt"
  echo "bar" > "$TMPDIR/bar.txt"
  md5foo=$(file_hash "$TMPDIR/foo.txt" md5)
  md5bar=$(file_hash "$TMPDIR/bar.txt" md5)
  {
    printf '%s  %s\n' "$md5foo" "foo.txt"
    printf '%s  %s\n' "$md5bar" "bar.txt"
  } > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 0 ]
}

@test "verify_md5_file returns 2 when manifest references missing file" {
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  printf '%s  %s\n' "$md5" "nonexistent.txt" > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 2 ]
}

@test "verify_md5_file returns 1 for malformed manifest line" {
  echo "not-a-valid-line" > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 1 ]
}
