#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/stat.sh'

setup() {
  TMPDIR=$(mktemp -d)
  echo "hello" > "$TMPDIR/file.txt"
  detect_stat
}

teardown() { rm -rf "$TMPDIR"; }

@test "stat_all_fields returns four fields" {
  run stat_all_fields "$TMPDIR/file.txt"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | awk -F'\t' '{print NF}')" -eq 4 ]
}

@test "stat_field size matches wc -c" {
  size=$(stat_field "$TMPDIR/file.txt" size)
  wcsize=$(wc -c < "$TMPDIR/file.txt")
  [ "$size" -eq "$wcsize" ]
}
