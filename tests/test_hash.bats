#!/usr/bin/env bats
load '../lib/hash.sh'

setup() {
  TMPDIR=$(mktemp -d)
  echo "hello world" > "$TMPDIR/file.txt"
}

teardown() { rm -rf "$TMPDIR"; }

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

@test "_do_hash_batch writes results for multiple files" {
  echo "foo" > "$TMPDIR/foo.txt"
  echo "bar" > "$TMPDIR/bar.txt"
  results="$TMPDIR/results.out"
  _do_hash_batch md5 "$results" "$TMPDIR/foo.txt" "$TMPDIR/bar.txt"
  grep -q "foo.txt" "$results"
  grep -q "bar.txt" "$results"
}
