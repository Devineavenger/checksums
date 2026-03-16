#!/usr/bin/env bats
# tests/test_guards.bats
#
# Tests for input validation and safety guards added to catch missing-argument
# errors, semaphore creation failures, and store-dir mkdir warnings.
#
# Verifies:
#  - Long options that require an argument fatal when invoked without one
#  - Semaphore FIFO creation guard fatals on unwritable TMPDIR
#  - _sidecar_path warns on unwritable store directory

load test_helper/bats-support/load
load test_helper/bats-assert/load

setup() {
  CHECKSUMS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/checksums.sh"
  chmod +x "$CHECKSUMS" 2>/dev/null || true
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chk_guard.XXXXXX")"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# --- Long option missing-argument guards ---

@test "--check without argument produces fatal error" {
  run bash "$CHECKSUMS" --check
  assert_failure
  assert_output --partial "--check requires an argument"
}

@test "--store-dir without argument produces fatal error" {
  run bash "$CHECKSUMS" --store-dir
  assert_failure
  assert_output --partial "--store-dir requires an argument"
}

@test "--exclude without argument produces fatal error" {
  run bash "$CHECKSUMS" --exclude
  assert_failure
  assert_output --partial "--exclude requires an argument"
}

@test "--include without argument produces fatal error" {
  run bash "$CHECKSUMS" --include
  assert_failure
  assert_output --partial "--include requires an argument"
}

@test "--per-file-algo without argument produces fatal error" {
  run bash "$CHECKSUMS" --per-file-algo
  assert_failure
  assert_output --partial "--per-file-algo requires an argument"
}

@test "--parallel without argument produces fatal error" {
  run bash "$CHECKSUMS" --parallel
  assert_failure
  assert_output --partial "--parallel requires an argument"
}

@test "--config without argument produces fatal error" {
  run bash "$CHECKSUMS" --config
  assert_failure
  assert_output --partial "--config requires an argument"
}

@test "--max-size without argument produces fatal error" {
  run bash "$CHECKSUMS" --max-size
  assert_failure
  assert_output --partial "--max-size requires an argument"
}

@test "--min-size without argument produces fatal error" {
  run bash "$CHECKSUMS" --min-size
  assert_failure
  assert_output --partial "--min-size requires an argument"
}

@test "--base-name without argument produces fatal error" {
  run bash "$CHECKSUMS" --base-name
  assert_failure
  assert_output --partial "--base-name requires an argument"
}

@test "--output without argument produces fatal error" {
  run bash "$CHECKSUMS" --output
  assert_failure
  assert_output --partial "--output requires an argument"
}

@test "--first-run-choice without argument produces fatal error" {
  run bash "$CHECKSUMS" --first-run-choice
  assert_failure
  assert_output --partial "--first-run-choice requires an argument"
}

@test "--meta-sig without argument produces fatal error" {
  run bash "$CHECKSUMS" --meta-sig
  assert_failure
  assert_output --partial "--meta-sig requires an argument"
}

@test "--log-base without argument produces fatal error" {
  run bash "$CHECKSUMS" --log-base
  assert_failure
  assert_output --partial "--log-base requires an argument"
}

@test "--parallel-dirs without argument produces fatal error" {
  run bash "$CHECKSUMS" --parallel-dirs
  assert_failure
  assert_output --partial "--parallel-dirs requires an argument"
}

@test "--batch without argument produces fatal error" {
  run bash "$CHECKSUMS" --batch
  assert_failure
  assert_output --partial "--batch requires an argument"
}

# --- Semaphore FIFO guard ---

@test "_sem_init fatals on unwritable TMPDIR" {
  # Source the libraries needed for _sem_init
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/init.sh"
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/logging.sh"
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/hash.sh"
  PARALLEL_JOBS=2
  # Point TMPDIR to a nonexistent path so mkfifo fails
  TMPDIR="$TEST_DIR/nonexistent/path"
  run _sem_init
  assert_failure
  assert_output --partial "Cannot create semaphore FIFO"
}
