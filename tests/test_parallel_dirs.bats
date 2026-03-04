#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/stat.sh'
load '../lib/usage.sh'
load '../lib/hash.sh'
load '../lib/args.sh'

setup() {
  TMPDIR=$(mktemp -d)
  detect_stat
}

teardown() { rm -rf "$TMPDIR"; }

@test "-P auto sets PARALLEL_DIRS to detected cores" {
  local expected
  expected=$(detect_cores)
  parse_args -p 4 -P auto "$TMPDIR"
  [ "$PARALLEL_DIRS" -eq "$expected" ]
  [ "$PARALLEL_DIRS" -ge 1 ]
}

@test "-P 1/2 sets PARALLEL_DIRS to half of cores (minimum 1)" {
  local cores
  cores=$(detect_cores)
  local expected=$(( (cores * 1 + 2 - 1) / 2 ))
  [ "$expected" -lt 1 ] && expected=1
  parse_args -p 4 -P 1/2 "$TMPDIR"
  [ "$PARALLEL_DIRS" -eq "$expected" ]
  [ "$PARALLEL_DIRS" -ge 1 ]
}

@test "-P 4 sets PARALLEL_DIRS to explicit integer" {
  parse_args -p 8 -P 4 "$TMPDIR"
  [ "$PARALLEL_DIRS" -eq 4 ]
}

@test "-P with invalid value exits with error" {
  run parse_args -P banana "$TMPDIR"
  [ "$status" -ne 0 ]
}

@test "PARALLEL_DIRS defaults to 1" {
  parse_args -p 4 "$TMPDIR"
  [ "$PARALLEL_DIRS" -eq 1 ]
}

@test "semaphore init and destroy cycle" {
  PARALLEL_JOBS=4
  _sem_init
  # FIFO should exist
  [ -n "$SEM_FIFO" ]
  [ -p "$SEM_FIFO" ]
  [ -n "$SEM_FD" ]

  # Acquire and release a token
  _sem_acquire
  _sem_release

  # Cleanup
  local fifo_path="$SEM_FIFO"
  _sem_destroy
  [ ! -e "$fifo_path" ]
  [ -z "$SEM_FD" ]
}

@test "semaphore limits concurrent workers to PARALLEL_JOBS" {
  PARALLEL_JOBS=2
  _sem_init

  # Acquire both tokens
  _sem_acquire
  _sem_acquire

  # Release one
  _sem_release

  # Should be able to acquire again (one available)
  _sem_acquire

  # Release all
  _sem_release
  _sem_release

  _sem_destroy
}
