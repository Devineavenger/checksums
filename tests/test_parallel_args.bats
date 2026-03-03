#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/stat.sh'
load '../lib/usage.sh'
load '../lib/args.sh'

setup() {
  TMPDIR=$(mktemp -d)
  detect_stat
}

teardown() { rm -rf "$TMPDIR"; }

@test "-p auto sets PARALLEL_JOBS to detected cores" {
  local expected
  expected=$(detect_cores)
  PARALLEL_JOBS="auto"
  # Simulate the validation section of parse_args
  parse_args -p auto "$TMPDIR"
  [ "$PARALLEL_JOBS" -eq "$expected" ]
  [ "$PARALLEL_JOBS" -ge 1 ]
}

@test "-p 1/2 sets PARALLEL_JOBS to half of cores (minimum 1)" {
  local cores
  cores=$(detect_cores)
  local expected=$(( (cores * 1 + 2 - 1) / 2 ))  # round up
  [ "$expected" -lt 1 ] && expected=1
  parse_args -p 1/2 "$TMPDIR"
  [ "$PARALLEL_JOBS" -eq "$expected" ]
  [ "$PARALLEL_JOBS" -ge 1 ]
}

@test "-p 3/4 sets PARALLEL_JOBS to 3/4 of cores (minimum 1)" {
  local cores
  cores=$(detect_cores)
  local expected=$(( (cores * 3 + 4 - 1) / 4 ))  # round up
  [ "$expected" -lt 1 ] && expected=1
  parse_args -p 3/4 "$TMPDIR"
  [ "$PARALLEL_JOBS" -eq "$expected" ]
  [ "$PARALLEL_JOBS" -ge 1 ]
}

@test "-p 1/4 sets PARALLEL_JOBS to 1/4 of cores (minimum 1)" {
  local cores
  cores=$(detect_cores)
  local expected=$(( (cores * 1 + 4 - 1) / 4 ))  # round up
  [ "$expected" -lt 1 ] && expected=1
  parse_args -p 1/4 "$TMPDIR"
  [ "$PARALLEL_JOBS" -eq "$expected" ]
  [ "$PARALLEL_JOBS" -ge 1 ]
}

@test "-p 4 sets PARALLEL_JOBS to explicit integer" {
  parse_args -p 4 "$TMPDIR"
  [ "$PARALLEL_JOBS" -eq 4 ]
}

@test "-p with invalid value exits with error" {
  run parse_args -p banana "$TMPDIR"
  [ "$status" -ne 0 ]
}
