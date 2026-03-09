#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/usage.sh'
load '../lib/args.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  SUM_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  LOG_BASE=""
  RUN_LOG=""
  LOG_FILEPATH=""
  errors=()
  log_level=3
  VERBOSE=0
  DEBUG=0
}

teardown() {
  rm -rf "$TMPDIR"
}

# --- Basic key=value parsing ---

@test "_load_config parses string values" {
  printf 'BASE_NAME=myproject\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "$BASE_NAME" = "myproject" ]
}

@test "_load_config parses integer values" {
  printf 'PARALLEL_JOBS=8\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "$PARALLEL_JOBS" = "8" ]
}

@test "_load_config strips double quotes from values" {
  printf 'PER_FILE_ALGO="sha256"\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "$PER_FILE_ALGO" = "sha256" ]
}

@test "_load_config strips single quotes from values" {
  printf "META_SIG_ALGO='md5'\n" > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "$META_SIG_ALGO" = "md5" ]
}

@test "_load_config skips blank lines and comments" {
  cat > "$TMPDIR/test.conf" <<'EOF'
# This is a comment
BASE_NAME=test1

# Another comment

VERBOSE=1
EOF
  _load_config "$TMPDIR/test.conf"
  [ "$BASE_NAME" = "test1" ]
  [ "$VERBOSE" = "1" ]
}

@test "_load_config handles whitespace around =" {
  printf 'BASE_NAME = spaced_value\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "$BASE_NAME" = "spaced_value" ]
}

@test "_load_config handles whitespace around = with quotes" {
  printf 'BASE_NAME = "quoted spaced"\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "$BASE_NAME" = "quoted spaced" ]
}

@test "_load_config warns on unknown key" {
  printf 'UNKNOWN_KEY=somevalue\n' > "$TMPDIR/test.conf"
  run _load_config "$TMPDIR/test.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown key"*"UNKNOWN_KEY"* ]]
}

@test "_load_config fatals on old bash array syntax" {
  printf 'EXCLUDE_PATTERNS=("*.tmp" "*.bak")\n' > "$TMPDIR/test.conf"
  run _load_config "$TMPDIR/test.conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *"old bash array syntax"* ]]
}

@test "_load_config handles empty value" {
  printf 'LOG_BASE=\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "$LOG_BASE" = "" ]
}

@test "_load_config handles special characters in value" {
  printf 'BASE_NAME=#####checksums#####\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "$BASE_NAME" = "#####checksums#####" ]
}

@test "_load_config parses multiple keys" {
  cat > "$TMPDIR/test.conf" <<'EOF'
BASE_NAME=multi_test
PER_FILE_ALGO=sha256
PARALLEL_JOBS=4
SKIP_EMPTY=0
LOG_FORMAT=json
EOF
  _load_config "$TMPDIR/test.conf"
  [ "$BASE_NAME" = "multi_test" ]
  [ "$PER_FILE_ALGO" = "sha256" ]
  [ "$PARALLEL_JOBS" = "4" ]
  [ "$SKIP_EMPTY" = "0" ]
  [ "$LOG_FORMAT" = "json" ]
}

@test "_load_config warns on line without =" {
  printf 'THIS_IS_INVALID\n' > "$TMPDIR/test.conf"
  run _load_config "$TMPDIR/test.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid line"* ]]
}

# --- Pattern comma-splitting ---

@test "_load_config splits EXCLUDE_PATTERNS comma-separated string into array" {
  EXCLUDE_PATTERNS=()
  printf 'EXCLUDE_PATTERNS=*.tmp,*.bak,*.swp\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "${#EXCLUDE_PATTERNS[@]}" -eq 3 ]
  [ "${EXCLUDE_PATTERNS[0]}" = "*.tmp" ]
  [ "${EXCLUDE_PATTERNS[1]}" = "*.bak" ]
  [ "${EXCLUDE_PATTERNS[2]}" = "*.swp" ]
}

@test "_load_config splits INCLUDE_PATTERNS comma-separated string into array" {
  INCLUDE_PATTERNS=()
  printf 'INCLUDE_PATTERNS=*.txt,*.md\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "${#INCLUDE_PATTERNS[@]}" -eq 2 ]
  [ "${INCLUDE_PATTERNS[0]}" = "*.txt" ]
  [ "${INCLUDE_PATTERNS[1]}" = "*.md" ]
}

@test "_load_config handles single pattern without comma" {
  EXCLUDE_PATTERNS=()
  printf 'EXCLUDE_PATTERNS=*.log\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "${#EXCLUDE_PATTERNS[@]}" -eq 1 ]
  [ "${EXCLUDE_PATTERNS[0]}" = "*.log" ]
}

@test "_load_config handles empty EXCLUDE_PATTERNS value" {
  EXCLUDE_PATTERNS=()
  printf 'EXCLUDE_PATTERNS=\n' > "$TMPDIR/test.conf"
  _load_config "$TMPDIR/test.conf"
  [ "${#EXCLUDE_PATTERNS[@]}" -eq 0 ]
}
