#!/usr/bin/env bats

# Load the helper functions directly
load '../lib/hash.sh'
load '../lib/first_run.sh'

setup() {
  TMPDIR=$(mktemp -d)
  echo "hello world" > "$TMPDIR/file.txt"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "file_hash computes md5 correctly" {
  run file_hash "$TMPDIR/file.txt" md5
  [ "$status" -eq 0 ]
  # md5 of "hello world\n" is 6f5902ac237024bdd0c176cb93063dc4
  [ "$output" = "6f5902ac237024bdd0c176cb93063dc4" ]
}

@test "file_hash computes sha256 correctly" {
  run file_hash "$TMPDIR/file.txt" sha256
  [ "$status" -eq 0 ]
  # sha256 of "hello world\n"
  [ "$output" = "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447" ]
}

@test "verify_md5_file returns 0 for valid file" {
  # Create a .md5 file
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  echo "$md5  file.txt" > "$TMPDIR/#####checksums#####.md5"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 0 ]
}
