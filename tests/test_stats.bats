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

@test "stat_field inode is a pure integer with no leading whitespace" {
  val=$(stat_field "$TMPDIR/file.txt" inode)
  [ -n "$val" ]
  [[ "$val" =~ ^[0-9]+$ ]]
}

@test "stat_field mtime is a pure integer with no leading whitespace" {
  val=$(stat_field "$TMPDIR/file.txt" mtime)
  [ -n "$val" ]
  [[ "$val" =~ ^[0-9]+$ ]]
}

@test "stat_field dev is a pure integer with no leading whitespace" {
  val=$(stat_field "$TMPDIR/file.txt" dev)
  [ -n "$val" ]
  [[ "$val" =~ ^[0-9]+$ ]]
}

@test "stat_all_fields first field has no leading whitespace" {
  raw=$(stat_all_fields "$TMPDIR/file.txt")
  inode="${raw%%$'\t'*}"
  [[ "$inode" != " "* ]]
  [[ "$inode" =~ ^[0-9]+$ ]]
}

@test "detect_cores returns a positive integer" {
  run detect_cores
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 1 ]
}

@test "detect_cores returns at least 1" {
  # Even in minimal environments, detect_cores must return >= 1
  cores=$(detect_cores)
  [ "$cores" -ge 1 ]
}
