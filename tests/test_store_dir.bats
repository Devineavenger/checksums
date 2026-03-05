#!/usr/bin/env bats
# test_store_dir.bats — tests for --store-dir / -D central manifest store

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
  STORE_DIR=""
  NO_ROOT_SIDEFILES=0
  SKIP_EMPTY=1
  RUN_LOG=""
  LOG_FILEPATH=""
}

teardown() {
  rm -rf "$TEST_TMPDIR" 2>/dev/null || true
}

@test "-D sets STORE_DIR" {
  local store="$TEST_TMPDIR/store"
  mkdir -p "$store"
  parse_args -D "$store" -y "$TEST_TMPDIR"
  [ "$STORE_DIR" = "$store" ]
}

@test "--store-dir sets STORE_DIR" {
  local store="$TEST_TMPDIR/store"
  mkdir -p "$store"
  parse_args --store-dir "$store" -y "$TEST_TMPDIR"
  [ "$STORE_DIR" = "$store" ]
}

@test "_sidecar_path returns store path when STORE_DIR set" {
  TARGET_DIR="$TEST_TMPDIR"
  STORE_DIR="$TEST_TMPDIR/store"
  local result
  result="$(_sidecar_path "$TEST_TMPDIR/sub" "$SUM_FILENAME")"
  [ "$result" = "$TEST_TMPDIR/store/sub/$SUM_FILENAME" ]
}

@test "_sidecar_path returns local path when STORE_DIR empty" {
  TARGET_DIR="$TEST_TMPDIR"
  STORE_DIR=""
  local result
  result="$(_sidecar_path "$TEST_TMPDIR/sub" "$SUM_FILENAME")"
  [ "$result" = "$TEST_TMPDIR/sub/$SUM_FILENAME" ]
}

@test "_sidecar_path handles root directory mapping" {
  TARGET_DIR="$TEST_TMPDIR"
  STORE_DIR="$TEST_TMPDIR/store"
  local result
  result="$(_sidecar_path "$TEST_TMPDIR" "$SUM_FILENAME")"
  [ "$result" = "$TEST_TMPDIR/store/$SUM_FILENAME" ]
}

@test "_runlog_path returns store path when STORE_DIR set" {
  TARGET_DIR="$TEST_TMPDIR"
  STORE_DIR="$TEST_TMPDIR/store"
  local result
  result="$(_runlog_path "test.run.log")"
  [ "$result" = "$TEST_TMPDIR/store/test.run.log" ]
}

@test "_runlog_path returns target path when STORE_DIR empty" {
  TARGET_DIR="$TEST_TMPDIR"
  STORE_DIR=""
  local result
  result="$(_runlog_path "test.run.log")"
  [ "$result" = "$TEST_TMPDIR/test.run.log" ]
}

@test "_sidecar_path creates store subdirectory" {
  TARGET_DIR="$TEST_TMPDIR"
  STORE_DIR="$TEST_TMPDIR/store"
  _sidecar_path "$TEST_TMPDIR/sub" "$SUM_FILENAME" > /dev/null
  [ -d "$TEST_TMPDIR/store/sub" ]
}

@test "config STORE_DIR=path works" {
  local store="$TEST_TMPDIR/store"
  mkdir -p "$store"
  local conf="$TEST_TMPDIR/test.conf"
  echo "STORE_DIR=$store" > "$conf"
  parse_args --config "$conf" -y "$TEST_TMPDIR"
  [ "$STORE_DIR" = "$store" ]
}

@test "build_exclusions sets STORE_DIR_EXCL for store inside target" {
  TARGET_DIR="$TEST_TMPDIR"
  STORE_DIR="$TEST_TMPDIR/.store"
  build_exclusions
  [ "$STORE_DIR_EXCL" = "$TEST_TMPDIR/.store" ]
}

@test "build_exclusions leaves STORE_DIR_EXCL empty for store outside target" {
  TARGET_DIR="$TEST_TMPDIR"
  STORE_DIR="/tmp/external_store_$$"
  build_exclusions
  [ -z "$STORE_DIR_EXCL" ]
}
