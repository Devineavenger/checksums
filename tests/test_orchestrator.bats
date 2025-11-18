#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/tools.sh'
load '../lib/stat.sh'
load '../lib/compat.sh'
load '../lib/orchestrator.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  TARGET_DIR="$TMPDIR"
  VERBOSE=2
  log_level=3
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "run_checksums aborts on system root" {
  TARGET_DIR="/"
  run run_checksums
  [ "$status" -eq 1 ]
}

# If you want to check the log file, run in the same shell:
@test "run_checksums aborts on system root (log file)" {
  TARGET_DIR="/"
  run run_checksums
  [ "$status" -eq 1 ]
  # The function writes to $TARGET_DIR/${BASE_NAME}.run.log
  logfile="${TARGET_DIR}/${BASE_NAME}.run.log"
  grep -q "Refusing to run on system root" "$logfile"
}
