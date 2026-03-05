#!/usr/bin/env bats
# test_algo_filenames.bats — tests for algorithm-based manifest filenames

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

@test "default algo (md5) creates .md5 manifest" {
  PER_FILE_ALGO=md5
  DRY_RUN=0
  VERIFY_ONLY=0
  SUM_FILENAME="${BASE_NAME}.md5"
  process_single_directory "$TEST_TMPDIR/sub"

  [ -f "$TEST_TMPDIR/sub/${BASE_NAME}.md5" ]
}

@test "sha256 algo creates .sha256 manifest" {
  PER_FILE_ALGO=sha256
  DRY_RUN=0
  VERIFY_ONLY=0
  SUM_FILENAME="${BASE_NAME}.sha256"
  process_single_directory "$TEST_TMPDIR/sub"

  [ -f "$TEST_TMPDIR/sub/${BASE_NAME}.sha256" ]
}

@test "sha1 algo creates .sha1 manifest" {
  if ! command -v sha1sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    skip "sha1sum/shasum not available"
  fi
  PER_FILE_ALGO=sha1
  DRY_RUN=0
  VERIFY_ONLY=0
  SUM_FILENAME="${BASE_NAME}.sha1"
  process_single_directory "$TEST_TMPDIR/sub"

  [ -f "$TEST_TMPDIR/sub/${BASE_NAME}.sha1" ]
}

@test "SUM_FILENAME derived correctly after parse_args -a sha256" {
  parse_args -a sha256 -y "$TEST_TMPDIR"
  [ "$SUM_FILENAME" = "${BASE_NAME}.sha256" ]
}

@test "SUM_FILENAME derived correctly after parse_args -a sha512" {
  parse_args -a sha512 -y "$TEST_TMPDIR"
  [ "$SUM_FILENAME" = "${BASE_NAME}.sha512" ]
}

@test "file_hash works with sha512" {
  if ! command -v sha512sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    skip "sha512sum/shasum not available"
  fi
  run file_hash "$TEST_TMPDIR/sub/file.txt" "sha512"
  assert_success
  # sha512 produces 128 hex chars
  assert_output --regexp '^[a-f0-9]{128}$'
}

@test "unsupported algo rejected by parse_args" {
  run parse_args -a blake2 -y "$TEST_TMPDIR"
  assert_failure
}
