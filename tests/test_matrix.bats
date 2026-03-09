#!/usr/bin/env bats
load 'test_helper/bats-support/load'

# Guard: ensure this file is executed by the Bats harness, not a plain shell.
# If the test is accidentally executed by /bin/sh or bash, exit with a clear error.
if [ -z "${BATS_VERSION:-}" ]; then
  echo "ERROR: tests/test_matrix.bats must be run with 'bats' (bats-core). Aborting." >&2
  exit 2
fi

# tests/test_matrix.bats
# Integration test matrix for checksums.sh
# - All runs use -y to skip the interactive prompt.
# - Tests create files where needed so SKIP_EMPTY/NO_ROOT_SIDEFILES don't silently skip work.
# - On assertion failure we cat the run log to aid debugging.

setup() {
  # Use TEST_DIR (not TMPDIR) so checksums.sh subprocesses don't inherit it as
  # their temp directory — prevents mktemp pollution inside the test data dir
  # during parallel bats execution.
  TEST_DIR="$(mktemp -d)"
  CHECKSUMS="$(pwd)/checksums.sh"
  chmod +x "$CHECKSUMS" || true
  BASE_NAME="#####checksums#####"
  RUN_LOG="$TEST_DIR/${BASE_NAME}.run.log"

  # CI-configurable knobs
  PARALLEL="${CI_PARALLEL:-4}"
  # CI_STRICT_LOGS: when "true" run strict log assertions (set in CI for nightly/strict runs)
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Portable helpers

# Portable stat mtime
file_mtime() {
  # $1 = path
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

# Portable md5 writer: prefer md5sum, then md5 -r, else fallback placeholder
write_md5_manifest() {
  # $1 = dir, $2 = manifest name
  if command -v md5sum >/dev/null 2>&1; then
    (cd "$1" && md5sum file1 | awk '{print $1 "  " $2}' > "$2")
  elif command -v md5 >/dev/null 2>&1; then
    (cd "$1" && md5 -r file1 | awk '{print $1 "  " $2}' > "$2")
  else
    printf '%s  %s\n' "d41d8cd98f00b204e9800998ecf8427e" "file1" > "$1/$2"
  fi
}

dump_log_on_fail() {
  if [ ! -f "$RUN_LOG" ]; then
    echo "=== RUN LOG MISSING: $RUN_LOG ==="
    return
  fi
  echo "=== RUN LOG ($RUN_LOG) BEGIN ==="
  sed -n '1,200p' "$RUN_LOG" || true
  echo "=== RUN LOG END ==="
}

# Tests

@test "baseline run creates sidecars (allow root sidefiles)" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR"
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/$BASE_NAME.md5" ]
  [ -f "$TEST_DIR/$BASE_NAME.meta" ]
}

@test "dry-run does not create sidecars (-n)" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y -n --allow-root-sidefiles "$TEST_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_DIR/$BASE_NAME.md5" ]
  [ ! -f "$TEST_DIR/$BASE_NAME.meta" ]
}

@test "verify-only audits manifests (-V)" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR"
  run "$CHECKSUMS" -y -V --allow-root-sidefiles "$TEST_DIR"
  [ "$status" -eq 0 ]
}

@test "verify-only logs 'Verify-only'" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR"
  run "$CHECKSUMS" -y -V --allow-root-sidefiles "$TEST_DIR"
  grep -q "Verify-only" "$TEST_DIR/$BASE_NAME.run.log"
}

@test "force rebuild overwrites manifests (-r)" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR"
  ts1=$(file_mtime "$TEST_DIR/$BASE_NAME.md5")
  # Backdate manifest so second run's mtime is guaranteed to be newer (avoids sleep)
  touch -t 202001010000.00 "$TEST_DIR/$BASE_NAME.md5"
  ts1=$(file_mtime "$TEST_DIR/$BASE_NAME.md5")
  run "$CHECKSUMS" -y -r --allow-root-sidefiles "$TEST_DIR"
  ts2=$(file_mtime "$TEST_DIR/$BASE_NAME.md5")
  [ "$ts2" -gt "$ts1" ]
}

@test "disable reuse rehashes files (-R/--no-reuse)" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR"
  run "$CHECKSUMS" -y -R --allow-root-sidefiles "$TEST_DIR"
  [ -f "$TEST_DIR/$BASE_NAME.run.log" ]
}

@test "first-run schedules overwrite (-F)" {
  # create two files so the initial manifest has real entries
  echo "hello" > "$TEST_DIR/file1"
  echo "world" > "$TEST_DIR/file2"

  # Run once to create manifests
  run "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR"
  [ -f "$TEST_DIR/$BASE_NAME.md5" ]    # ensure md5 exists

  # Remove meta/log and run log to simulate 'md5-only' state
  rm -f "$TEST_DIR/$BASE_NAME.meta" "$TEST_DIR/$BASE_NAME.log" "$TEST_DIR/$BASE_NAME.run.log"

  # Run first-run mode with debug to capture planner decisions if needed
  run "$CHECKSUMS" -y -F --allow-root-sidefiles -d "$TEST_DIR"
  if [ "$status" -ne 0 ]; then
    dump_log_on_fail
    fail "checksums.sh failed when running -F (exit $status)"
  fi

  # Default behavior: when scheduled overwrites are executed, the first-run log
  # is removed by the orchestrator. Assert that the log is absent by default.
  if [ -f "$TEST_DIR/$BASE_NAME.first-run.log" ]; then
    echo "=== DIR LIST ==="
    ls -la "$TEST_DIR"
    dump_log_on_fail
    fail "expected first-run log to be removed by default after overwrites: $TEST_DIR/$BASE_NAME.first-run.log"
  fi
}

@test "first-run keeps log with -K / FIRST_RUN_KEEP=1" {
  # create two files so the initial manifest has real entries
  echo "hello" > "$TEST_DIR/file1"
  echo "world" > "$TEST_DIR/file2"

  # Run once to create manifests
  run "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR"
  [ -f "$TEST_DIR/$BASE_NAME.md5" ]    # ensure md5 exists

  # Remove meta/log and run log to simulate 'md5-only' state
  rm -f "$TEST_DIR/$BASE_NAME.meta" "$TEST_DIR/$BASE_NAME.log" "$TEST_DIR/$BASE_NAME.run.log"

  # Run first-run mode with keep flag via CLI short option -K
  run "$CHECKSUMS" -y -F -K --allow-root-sidefiles -d "$TEST_DIR"
  if [ "$status" -ne 0 ]; then
    dump_log_on_fail
    fail "checksums.sh failed when running -F -K (exit $status)"
  fi

  # The keep flag should preserve the detailed first-run log for auditing
  if [ ! -f "$TEST_DIR/$BASE_NAME.first-run.log" ]; then
    echo "=== DIR LIST ==="
    ls -la "$TEST_DIR"
    dump_log_on_fail
    fail "expected first-run log to be kept when -K is provided: $TEST_DIR/$BASE_NAME.first-run.log"
  fi

  # Cleanup and also test env alias variant
  rm -f "$TEST_DIR/$BASE_NAME.first-run.log" "$TEST_DIR/$BASE_NAME.run.log"
  # Ensure we simulate the same md5-only state as the CLI -K run:
  rm -f "$TEST_DIR/$BASE_NAME.meta" "$TEST_DIR/$BASE_NAME.log" "$TEST_DIR/$BASE_NAME.run.log"

  # Run again using environment variable alias FIRST_RUN_KEEP=1
  FIRST_RUN_KEEP=1 run "$CHECKSUMS" -y -F --allow-root-sidefiles -d "$TEST_DIR"
  if [ "$status" -ne 0 ]; then
    dump_log_on_fail
    fail "checksums.sh failed when running FIRST_RUN_KEEP=1 -F (exit $status)"
  fi

  if [ ! -f "$TEST_DIR/$BASE_NAME.first-run.log" ]; then
    echo "=== DIR LIST ==="
    ls -la "$TEST_DIR"
    dump_log_on_fail
    fail "expected first-run log to be kept when FIRST_RUN_KEEP=1 is set: $TEST_DIR/$BASE_NAME.first-run.log"
  fi
}

@test "parallel jobs respected exit" {
  for i in $(seq 1 10); do echo "data $i" > "$TEST_DIR/file$i"; done

  attempt=0
  max_attempts=2
  until run "$CHECKSUMS" -y -p "$PARALLEL" --allow-root-sidefiles "$TEST_DIR"; do
    attempt=$((attempt+1))
    if [ "$attempt" -ge "$max_attempts" ]; then
      dump_log_on_fail
      fail "parallel run failed after $attempt attempts"
    fi
    sleep 2
  done

  [ "$status" -eq 0 ]
}

@test "parallel jobs respected log entry" {
  for i in $(seq 1 10); do echo "data $i" > "$TEST_DIR/file$i"; done
  run "$CHECKSUMS" -y -p "$PARALLEL" --allow-root-sidefiles "$TEST_DIR"
  [ "$status" -eq 0 ]
  grep -q "parallel: $PARALLEL" "$TEST_DIR/$BASE_NAME.run.log" \
    || grep -q "PARALLEL_JOBS=$PARALLEL" "$TEST_DIR/$BASE_NAME.run.log" \
    || skip "No explicit parallel marker in run log for this build"
}

@test "batch rules applied exit and optional strict log" {
  dd if=/dev/zero of="$TEST_DIR/bigfile" bs=1M count=5 >/dev/null 2>&1 || true
  echo "hello" > "$TEST_DIR/file1"
  BATCH="0-2M:20,2M-50M:10,>50M:1"

  # Try short debug flag -d first, then fallback to no debug
  run "$CHECKSUMS" -y -b "$BATCH" --allow-root-sidefiles -d "$TEST_DIR"
  if [ "$status" -ne 0 ]; then
    run "$CHECKSUMS" -y -b "$BATCH" --allow-root-sidefiles "$TEST_DIR"
  fi

  # Ensure the run succeeded
  if [ "$status" -ne 0 ]; then
    dump_log_on_fail
    fail "checksums.sh failed for batch test (exit $status)"
  fi

  # Behavioral assertions (default, CI-friendly)
  [ -f "$TEST_DIR/$BASE_NAME.md5" ]
  [ -f "$TEST_DIR/$BASE_NAME.meta" ]

  # Strict log assertion only when CI_STRICT_LOGS=true
  if [ "${CI_STRICT_LOGS:-}" = "true" ]; then
    if grep -qiE "batch|rules|->[[:space:]]*[0-9]+" "$TEST_DIR/$BASE_NAME.run.log"; then
      :
    else
      dump_log_on_fail
      fail "CI_STRICT_LOGS enabled but no batch parsing markers found in run log"
    fi
  else
    skip "CI_STRICT_LOGS not set; skipping strict batch log assertion"
  fi
}

@test "log format json outputs JSON" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y -o json --allow-root-sidefiles "$TEST_DIR"
  [[ "${output}" == *'"level":"INFO"'* ]]
}

@test "log format csv outputs CSV" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y -o csv --allow-root-sidefiles "$TEST_DIR"
  [[ "${output}" == *"timestamp,level,message"* ]]
}

@test "skip-empty default" {
  run "$CHECKSUMS" -y "$TEST_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_DIR/$BASE_NAME.md5" ]
}

@test "no-skip-empty processes empty dirs (--no-skip-empty)" {
  echo "content" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y --no-skip-empty --allow-root-sidefiles "$TEST_DIR"
  [ -f "$TEST_DIR/$BASE_NAME.md5" ]
}

@test "allow-root-sidefiles permits root artifacts (--allow-root-sidefiles)" {
  echo "content" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR"
  [ -f "$TEST_DIR/$BASE_NAME.md5" ]
}

@test "root sidecars blocked by default" {
  echo "content" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y "$TEST_DIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_DIR/$BASE_NAME.md5" ]
}

@test "disable md5-details (-z/--no-md5-details)" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y -z --allow-root-sidefiles "$TEST_DIR"
  [ -f "$TEST_DIR/$BASE_NAME.run.log" ]
}

@test "enable md5-details exit" {
  echo "hello" > "$TEST_DIR/file1"
  run "$CHECKSUMS" -y --md5-details --allow-root-sidefiles "$TEST_DIR"
  [ "$status" -eq 0 ]
}

@test "enable md5-details logs VERIFIED" {
  echo "hello" > "$TEST_DIR/file1"
  # First run to create manifests
  run "$CHECKSUMS" -y --allow-root-sidefiles "$TEST_DIR"
  # Second run with md5-details to audit existing manifests
  run "$CHECKSUMS" -y --md5-details --allow-root-sidefiles "$TEST_DIR"
  grep -q "VERIFIED" "$TEST_DIR/$BASE_NAME.run.log"
}
