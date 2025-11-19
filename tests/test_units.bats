#!/usr/bin/env bats
load '../lib/fs.sh'

setup() {
  TMPDIR=$(mktemp -d)
}

teardown() { rm -rf "$TMPDIR"; }

@test "normalize_unit handles plain numbers" {
  run normalize_unit 1000
  [ "$status" -eq 0 ]
  [ "$output" = "1000" ]
}

@test "normalize_unit handles bytes suffix" {
  run normalize_unit 42B
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
}

@test "normalize_unit handles kilobytes" {
  run normalize_unit 1K
  [ "$output" = "1K" ]
  run normalize_unit 2kb
  [ "$output" = "2K" ]
  run normalize_unit 3KiB
  [ "$output" = "3K" ]
}

@test "normalize_unit handles megabytes" {
  run normalize_unit 1M
  [ "$output" = "1M" ]
  run normalize_unit 2MB
  [ "$output" = "2M" ]
  run normalize_unit 3mib
  [ "$output" = "3M" ]
}

@test "normalize_unit handles gigabytes" {
  run normalize_unit 1G
  [ "$output" = "1G" ]
  run normalize_unit 2GB
  [ "$output" = "2G" ]
  run normalize_unit 3GiB
  [ "$output" = "3G" ]
}

@test "normalize_unit handles terabytes" {
  run normalize_unit 1T
  [ "$output" = "1T" ]
  run normalize_unit 2TB
  [ "$output" = "2T" ]
  run normalize_unit 3tib
  [ "$output" = "3T" ]
}

@test "normalize_unit handles petabytes" {
  run normalize_unit 1P
  [ "$output" = "1P" ]
  run normalize_unit 2PB
  [ "$output" = "2P" ]
  run normalize_unit 3PiB
  [ "$output" = "3P" ]
}

@test "normalize_unit handles exabytes" {
  run normalize_unit 1E
  [ "$output" = "1E" ]
  run normalize_unit 2EB
  [ "$output" = "2E" ]
  run normalize_unit 3EiB
  [ "$output" = "3E" ]
}

@test "normalize_unit leaves unknown suffix unchanged" {
  run normalize_unit 5Z
  [ "$output" = "5Z" ]
}
