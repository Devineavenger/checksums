#!/usr/bin/env bats
# test_quiet.bats — tests for quiet mode (-q / --quiet)

load test_helper/bats-support/load
load test_helper/bats-assert/load

setup() {
  source "$BATS_TEST_DIRNAME/../lib/init.sh"
  source "$BATS_TEST_DIRNAME/../lib/color.sh"
  source "$BATS_TEST_DIRNAME/../lib/logging.sh"
  source "$BATS_TEST_DIRNAME/../lib/usage.sh"
  source "$BATS_TEST_DIRNAME/../lib/meta.sh"
  source "$BATS_TEST_DIRNAME/../lib/stat.sh"
  source "$BATS_TEST_DIRNAME/../lib/fs.sh"
  source "$BATS_TEST_DIRNAME/../lib/hash.sh"
  source "$BATS_TEST_DIRNAME/../lib/tools.sh"
  source "$BATS_TEST_DIRNAME/../lib/compat.sh"
  source "$BATS_TEST_DIRNAME/../lib/process.sh"
  source "$BATS_TEST_DIRNAME/../lib/args.sh"
  detect_tools
  detect_stat

  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/sub"
  echo "hello" > "$TEST_TMPDIR/sub/file.txt"
  TARGET_DIR="$TEST_TMPDIR"
  NO_ROOT_SIDEFILES=0
  SKIP_EMPTY=1
  RUN_LOG=""
  LOG_FILEPATH=""
}

teardown() {
  rm -rf "$TEST_TMPDIR" 2>/dev/null || true
}

@test "-q sets QUIET=1" {
  parse_args -q -y "$TEST_TMPDIR"
  [ "$QUIET" -eq 1 ]
}

@test "--quiet sets QUIET=1" {
  parse_args --quiet -y "$TEST_TMPDIR"
  [ "$QUIET" -eq 1 ]
}

@test "-q suppresses INFO output (log_level=0)" {
  QUIET=1
  log_level=0
  run log "this should not appear"
  assert_output ""
}

@test "fatal still outputs in quiet mode" {
  QUIET=1
  log_level=0
  # fatal calls _global_log 0 then exit 1; capture both
  run fatal "critical error"
  assert_failure
  assert_output --partial "critical error"
}
