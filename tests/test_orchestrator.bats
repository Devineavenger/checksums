#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/usage.sh'
load '../lib/args.sh'
load '../lib/tools.sh'
load '../lib/stat.sh'
load '../lib/compat.sh'
load '../lib/hash.sh'
load '../lib/fs.sh'
load '../lib/meta.sh'
load '../lib/first_run.sh'
load '../lib/planner.sh'
load '../lib/process.sh'
load '../lib/orchestrator.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  SUM_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  LOG_BASE=""
  TARGET_DIR="$TMPDIR"
  VERBOSE=2
  log_level=3
  RUN_LOG=""
  LOG_FILEPATH=""
  errors=()
  count_errors=0
  detect_tools
  detect_stat
  check_bash_version
  build_exclusions
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
  if [ -f "$logfile" ]; then
    grep -q "Refusing to run on system root" "$logfile"
  else
    # CI runners usually cannot write to '/', so the log might be absent.
    # In that case, assert the refusal message was emitted to output.
    echo "$output" | grep -q "Refusing to run on system root"
  fi
}

@test "run log uses correct name when config overrides BASE_NAME" {
  NEW_BASE="myproject"
  printf 'BASE_NAME="%s"\n' "$NEW_BASE" > "$TMPDIR/${BASE_NAME}.conf"
  mkdir "$TMPDIR/sub"
  echo "data" > "$TMPDIR/sub/data.txt"
  local _orig_base="$BASE_NAME"
  # parse_args loads the config (changing BASE_NAME) then runs getopts so
  # any CLI flags still win.  run_checksums then sees the already-resolved
  # BASE_NAME and creates the run log with the correct name from the start.
  YES=1
  parse_args "$TMPDIR"
  run run_checksums
  # Log must exist under the name the config declared
  [ -f "$TMPDIR/${NEW_BASE}.run.log" ]
  # Orphaned log from the original BASE_NAME must not exist
  [ ! -f "$TMPDIR/${_orig_base}.run.log" ]
}

@test "run log is created in TARGET_DIR with the expected name" {
  mkdir "$TMPDIR/sub"
  echo "data" > "$TMPDIR/sub/data.txt"
  YES=1
  run run_checksums
  [ -f "$TMPDIR/${BASE_NAME}.run.log" ]
}
