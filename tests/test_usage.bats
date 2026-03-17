#!/usr/bin/env bats
# test_usage.bats — tests for usage/help output and lib sourcing sanity

load test_helper/bats-support/load
load test_helper/bats-assert/load

# Runs the main script with --help and verifies clean output.
@test "--help prints usage without errors on stderr" {
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" --help 2>&1
  assert_success
  assert_output --partial "Usage:"
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

# Ensures the version flag produces clean output.
@test "--version prints version without errors" {
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" --version 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

# Sources usage.sh directly and calls usage() to catch variable declaration bugs.
@test "usage() function produces output without errors" {
  source "$BATS_TEST_DIRNAME/../lib/init.sh"
  source "$BATS_TEST_DIRNAME/../lib/color.sh"
  source "$BATS_TEST_DIRNAME/../lib/usage.sh"
  run usage
  assert_success
  assert_output --partial "Usage:"
  refute_output --partial "command not found"
}

# ---------------------------------------------------------------------------
# Library sourcing sanity
#
# Each lib/*.sh is sourced in a subshell to catch syntax errors, bad variable
# declarations (e.g. bare word after command substitution), and other parse-
# time or source-time failures.  The full loader chain is used so that inter-
# module dependencies are satisfied.
# ---------------------------------------------------------------------------

# Helper: sources the full lib stack and returns stderr.
# Any "command not found", "syntax error", or non-zero exit means a bug.
_source_all_libs() {
  bash -c '
    set -euo pipefail
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/loader.sh"
  ' 2>&1
}

@test "all lib/*.sh files source without errors" {
  run _source_all_libs
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
  refute_output --partial "unbound variable"
}

# Per-file sourcing tests — catch which specific module is broken.

@test "lib/init.sh sources cleanly" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/color.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/compat.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/compat.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/logging.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/stat.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/stat.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/meta.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/meta.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/fs.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/fs.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/hash.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/hash.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/tools.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/tools.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/usage.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/usage.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/args.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/usage.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/compat.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/args.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/first_run.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/first_run.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/process.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/meta.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/stat.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/fs.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/hash.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/process.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/planner.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/meta.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/stat.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/fs.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/planner.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/status.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/status.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/orchestrator.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/compat.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/usage.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/meta.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/stat.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/fs.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/hash.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/tools.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/first_run.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/process.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/planner.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/status.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/args.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/orchestrator.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/verification.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/hash.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/verification.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/menu.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/menu.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "lib/loader.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/loader.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}
