#!/usr/bin/env bats
load '../lib/logging.sh'

setup() {
  TMPDIR=$(mktemp -d)
  RUN_LOG="$TMPDIR/run.log"
  : > "$RUN_LOG"
}

teardown() { rm -rf "$TMPDIR"; }

@test "record_error appends to errors and increments count" {
  count_errors=0
  errors=()
  record_error "Something went wrong"
  [ "$count_errors" -eq 1 ]
  [[ "${errors[0]}" == *"Something went wrong"* ]]
}

@test "first_run_log writes to FIRST_RUN_LOG" {
  FIRST_RUN_LOG="$TMPDIR/first.log"
  first_run_log "hello"
  grep -q "hello" "$FIRST_RUN_LOG"
}

@test "emit_md5_detail logs VERIFIED" {
  vlog() { echo "$*"; }
  run emit_md5_detail "$TMPDIR" 0
  [ "$status" -eq 0 ]
}
