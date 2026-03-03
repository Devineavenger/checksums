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
  [ "$status" -eq 0 ]; [ "$output" = "1K" ]
  run normalize_unit 2kb
  [ "$status" -eq 0 ]; [ "$output" = "2K" ]
  run normalize_unit 3KiB
  [ "$status" -eq 0 ]; [ "$output" = "3K" ]
}

@test "normalize_unit handles megabytes" {
  run normalize_unit 1M
  [ "$status" -eq 0 ]; [ "$output" = "1M" ]
  run normalize_unit 2MB
  [ "$status" -eq 0 ]; [ "$output" = "2M" ]
  run normalize_unit 3mib
  [ "$status" -eq 0 ]; [ "$output" = "3M" ]
}

@test "normalize_unit handles gigabytes" {
  run normalize_unit 1G
  [ "$status" -eq 0 ]; [ "$output" = "1G" ]
  run normalize_unit 2GB
  [ "$status" -eq 0 ]; [ "$output" = "2G" ]
  run normalize_unit 3GiB
  [ "$status" -eq 0 ]; [ "$output" = "3G" ]
}

@test "normalize_unit handles terabytes" {
  run normalize_unit 1T
  [ "$status" -eq 0 ]; [ "$output" = "1T" ]
  run normalize_unit 2TB
  [ "$status" -eq 0 ]; [ "$output" = "2T" ]
  run normalize_unit 3tib
  [ "$status" -eq 0 ]; [ "$output" = "3T" ]
}

@test "normalize_unit handles petabytes" {
  run normalize_unit 1P
  [ "$status" -eq 0 ]; [ "$output" = "1P" ]
  run normalize_unit 2PB
  [ "$status" -eq 0 ]; [ "$output" = "2P" ]
  run normalize_unit 3PiB
  [ "$status" -eq 0 ]; [ "$output" = "3P" ]
}

@test "normalize_unit handles exabytes" {
  run normalize_unit 1E
  [ "$status" -eq 0 ]; [ "$output" = "1E" ]
  run normalize_unit 2EB
  [ "$status" -eq 0 ]; [ "$output" = "2E" ]
  run normalize_unit 3EiB
  [ "$status" -eq 0 ]; [ "$output" = "3E" ]
}

@test "normalize_unit leaves unknown suffix unchanged" {
  run normalize_unit 5Z
  [ "$status" -eq 0 ]; [ "$output" = "5Z" ]
}
