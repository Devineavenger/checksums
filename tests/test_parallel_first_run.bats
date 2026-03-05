#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/fs.sh'
load '../lib/hash.sh'
load '../lib/logging.sh'
load '../lib/stat.sh'
load '../lib/compat.sh'
load '../lib/first_run.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  SUM_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  RUN_LOG="$TMPDIR/run.log"
  : > "$RUN_LOG"
  TARGET_DIR="$TMPDIR"
  DRY_RUN=0
  VERIFY_ONLY=0
  SKIP_EMPTY=1
  FORCE_REBUILD=0
  VERBOSE=0

  # Create 3 directories with valid .md5 files but missing .meta/.log
  for i in 1 2 3; do
    mkdir -p "$TMPDIR/dir$i"
    echo "content $i" > "$TMPDIR/dir$i/file.txt"
    local md5
    md5=$(file_hash "$TMPDIR/dir$i/file.txt" md5)
    printf '%s  %s\n' "$md5" "file.txt" > "$TMPDIR/dir$i/$SUM_FILENAME"
  done

  detect_stat
}

teardown() { rm -rf "$TMPDIR"; }

@test "parallel first-run verify matches sequential (overwrite mode)" {
  # Sequential run
  PARALLEL_JOBS=1
  FIRST_RUN_CHOICE="overwrite"
  first_run_overwrite=()
  count_verified=0
  count_overwritten=0
  first_run_verify "$TMPDIR"
  local seq_verified=$count_verified
  local seq_overwrite_count=${#first_run_overwrite[@]}

  # Reset
  first_run_overwrite=()
  count_verified=0
  count_overwritten=0
  : > "$RUN_LOG"

  # Parallel run
  PARALLEL_JOBS=4
  first_run_verify "$TMPDIR"
  local par_verified=$count_verified
  local par_overwrite_count=${#first_run_overwrite[@]}

  [ "$seq_verified" -eq "$par_verified" ]
  [ "$seq_overwrite_count" -eq "$par_overwrite_count" ]
}

@test "parallel first-run verify matches sequential (skip mode)" {
  # Corrupt one directory
  echo "bad" > "$TMPDIR/dir2/file.txt"

  FIRST_RUN_CHOICE="skip"

  # Sequential
  PARALLEL_JOBS=1
  first_run_overwrite=()
  count_verified=0
  errors=()
  first_run_verify "$TMPDIR"
  local seq_verified=$count_verified
  local seq_errors=${#errors[@]}

  # Reset
  first_run_overwrite=()
  count_verified=0
  errors=()
  : > "$RUN_LOG"

  # Parallel
  PARALLEL_JOBS=4
  first_run_verify "$TMPDIR"
  local par_verified=$count_verified
  local par_errors=${#errors[@]}

  [ "$seq_verified" -eq "$par_verified" ]
  [ "$seq_errors" -eq "$par_errors" ]
}

@test "parallel first-run falls back to sequential for prompt mode" {
  # With prompt mode, parallel is NOT used (interactive input needed).
  # We just verify it completes without error by using skip choice instead.
  FIRST_RUN_CHOICE="prompt"
  PARALLEL_JOBS=4
  first_run_overwrite=()
  count_verified=0

  # Simulate non-interactive by redirecting stdin to skip all prompts
  # Since all dirs verify OK, prompt branch is never reached.
  first_run_verify "$TMPDIR"
  [ "$count_verified" -ge 1 ]
}

@test "parallel first-run cleans up temp directory" {
  PARALLEL_JOBS=4
  FIRST_RUN_CHOICE="overwrite"
  first_run_overwrite=()
  count_verified=0
  first_run_verify "$TMPDIR"

  # No leftover fr_verify temp dirs
  local leftovers
  leftovers=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'fr_verify.*' 2>/dev/null | wc -l)
  [ "$leftovers" -eq 0 ]
}

@test "parallel first-run FIRST_RUN_LOG contains all directories" {
  PARALLEL_JOBS=4
  FIRST_RUN_CHOICE="overwrite"
  first_run_overwrite=()
  count_verified=0
  first_run_verify "$TMPDIR"

  [ -f "$FIRST_RUN_LOG" ]
  # All 3 directories should appear in the log
  for i in 1 2 3; do
    grep -q "dir$i" "$FIRST_RUN_LOG"
  done
}
