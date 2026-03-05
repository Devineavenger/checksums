#!/usr/bin/env bats
# test_minimal.bats — tests for minimal mode (-M / --minimal)

load test_helper/bats-support/load
load test_helper/bats-assert/load

setup() {
  source "$BATS_TEST_DIRNAME/../lib/init.sh"
  source "$BATS_TEST_DIRNAME/../lib/color.sh"
  source "$BATS_TEST_DIRNAME/../lib/logging.sh"
  source "$BATS_TEST_DIRNAME/../lib/meta.sh"
  source "$BATS_TEST_DIRNAME/../lib/stat.sh"
  source "$BATS_TEST_DIRNAME/../lib/fs.sh"
  source "$BATS_TEST_DIRNAME/../lib/hash.sh"
  source "$BATS_TEST_DIRNAME/../lib/tools.sh"
  source "$BATS_TEST_DIRNAME/../lib/compat.sh"
  source "$BATS_TEST_DIRNAME/../lib/process.sh"
  source "$BATS_TEST_DIRNAME/../lib/usage.sh"
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

@test "-M flag sets MINIMAL=1" {
  MINIMAL=0
  parse_args -M -y "$TEST_TMPDIR"
  [ "$MINIMAL" -eq 1 ]
}

@test "--minimal long flag sets MINIMAL=1" {
  MINIMAL=0
  parse_args --minimal -y "$TEST_TMPDIR"
  [ "$MINIMAL" -eq 1 ]
}

@test "minimal mode creates .md5 but not .meta or .log" {
  MINIMAL=1
  DRY_RUN=0
  VERIFY_ONLY=0
  process_single_directory "$TEST_TMPDIR/sub"

  [ -f "$TEST_TMPDIR/sub/$SUM_FILENAME" ]
  [ ! -f "$TEST_TMPDIR/sub/$META_FILENAME" ]
  [ ! -f "$TEST_TMPDIR/sub/$LOG_FILENAME" ]
}

@test "minimal mode .md5 contains correct hash format" {
  MINIMAL=1
  DRY_RUN=0
  VERIFY_ONLY=0
  process_single_directory "$TEST_TMPDIR/sub"

  # Should be in md5sum format: hash  ./filename
  run cat "$TEST_TMPDIR/sub/$SUM_FILENAME"
  assert_output --regexp '^[a-f0-9]+  \./file\.txt$'
}

@test "minimal mode forces FIRST_RUN=0" {
  FIRST_RUN=1
  MINIMAL=1
  parse_args -M -F -y "$TEST_TMPDIR"
  [ "$FIRST_RUN" -eq 0 ]
}

@test "write_meta is no-op in minimal mode" {
  MINIMAL=1
  local metafile="$TEST_TMPDIR/test.meta"
  write_meta "$metafile" "testline"
  [ ! -f "$metafile" ]
}

@test "verify_meta_sig returns 0 in minimal mode" {
  MINIMAL=1
  run verify_meta_sig "/nonexistent/file.meta"
  assert_success
}
