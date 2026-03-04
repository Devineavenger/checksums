#!/usr/bin/env bats
# test_progress.bats — tests for progress reporting helpers

load test_helper/bats-support/load
load test_helper/bats-assert/load

setup() {
  source "$BATS_TEST_DIRNAME/../lib/init.sh"
  source "$BATS_TEST_DIRNAME/../lib/color.sh"
  source "$BATS_TEST_DIRNAME/../lib/logging.sh"
  source "$BATS_TEST_DIRNAME/../lib/orchestrator.sh"
  TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
  _progress_cleanup 2>/dev/null || true
  rm -rf "$TEST_TMPDIR" 2>/dev/null || true
}

@test "_progress_init creates counter file and sets totals" {
  # Force TTY check to pass by overriding _PROG_ACTIVE directly
  PROGRESS=1
  _PROG_FILE="$(mktemp)"
  echo 0 > "$_PROG_FILE"
  _PROG_DIR_TOTAL=10
  _PROG_FILE_TOTAL=500
  _PROG_START=$(date +%s)
  _PROG_ACTIVE=1

  [ -f "$_PROG_FILE" ]
  [ "$_PROG_DIR_TOTAL" -eq 10 ]
  [ "$_PROG_FILE_TOTAL" -eq 500 ]
  local count
  count=$(<"$_PROG_FILE")
  [ "$count" -eq 0 ]
}

@test "_progress_file_done increments counter" {
  _PROG_FILE="$(mktemp)"
  echo 0 > "$_PROG_FILE"
  _PROG_ACTIVE=1

  _progress_file_done
  local count
  count=$(<"$_PROG_FILE")
  [ "$count" -eq 1 ]

  _progress_file_done
  _progress_file_done
  count=$(<"$_PROG_FILE")
  [ "$count" -eq 3 ]
}

@test "progress suppressed when PROGRESS=0" {
  PROGRESS=0
  _progress_init 10 100
  [ "${_PROG_ACTIVE}" -eq 0 ]
  [ -z "${_PROG_FILE}" ]
}

@test "progress suppressed when total files is 0" {
  PROGRESS=1
  _progress_init 0 0
  [ "${_PROG_ACTIVE}" -eq 0 ]
}

@test "_progress_cleanup removes counter file" {
  _PROG_FILE="$(mktemp)"
  echo 5 > "$_PROG_FILE"
  _PROG_ACTIVE=1

  local saved="$_PROG_FILE"
  _progress_cleanup 2>/dev/null
  [ ! -f "$saved" ]
  [ "${_PROG_ACTIVE}" -eq 0 ]
  [ -z "${_PROG_FILE}" ]
}

@test "_format_eta formats seconds correctly" {
  run _format_eta 45
  assert_output "45s"

  run _format_eta 125
  assert_output "2m5s"

  run _format_eta 3725
  assert_output "1h2m"
}

@test "_progress_file_done is no-op when inactive" {
  _PROG_ACTIVE=0
  _PROG_FILE=""
  # Should not error
  _progress_file_done
}
