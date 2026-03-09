#!/usr/bin/env bats
# test_patterns.bats — tests for --exclude / --include file filtering
load '../lib/fs.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  SUM_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  LOG_BASE="#####checksums#####"
  ALT_LOG_EXCL="#####checksums#####"
  LOCK_SUFFIX=".lock"
  SUM_EXCL="$(_safe_name "$(basename "$SUM_FILENAME")")"
  META_EXCL="$(_safe_name "$(basename "$META_FILENAME")")"
  LOG_EXCL="$(_safe_name "$(basename "$LOG_FILENAME")")"
  RUN_EXCL="$(_safe_name "${LOG_BASE}.run.log")"
  FIRST_RUN_EXCL="$(_safe_name "${LOG_BASE}.first-run.log")"
  LOCK_EXCL="${META_EXCL}${LOCK_SUFFIX}"
  EXCLUDE_PATTERNS=()
  INCLUDE_PATTERNS=()
}

teardown() { rm -rf "$TMPDIR"; }

# --- find_file_expr ---

@test "find_file_expr excludes files matching EXCLUDE_PATTERNS" {
  echo "data" > "$TMPDIR/a.txt"
  echo "data" > "$TMPDIR/b.tmp"
  EXCLUDE_PATTERNS=("*.tmp")
  result=$(find_file_expr "$TMPDIR" | tr '\0' '\n')
  [[ "$result" == *"a.txt"* ]]
  [[ "$result" != *"b.tmp"* ]]
}

@test "find_file_expr includes only files matching INCLUDE_PATTERNS" {
  echo "data" > "$TMPDIR/a.txt"
  echo "data" > "$TMPDIR/b.dat"
  INCLUDE_PATTERNS=("*.txt")
  result=$(find_file_expr "$TMPDIR" | tr '\0' '\n')
  [[ "$result" == *"a.txt"* ]]
  [[ "$result" != *"b.dat"* ]]
}

@test "find_file_expr applies both EXCLUDE and INCLUDE" {
  echo "data" > "$TMPDIR/a.txt"
  echo "data" > "$TMPDIR/b.txt.bak"
  echo "data" > "$TMPDIR/c.dat"
  INCLUDE_PATTERNS=("*.txt" "*.txt.bak")
  EXCLUDE_PATTERNS=("*.bak")
  result=$(find_file_expr "$TMPDIR" | tr '\0' '\n')
  [[ "$result" == *"a.txt"* ]]
  [[ "$result" != *"b.txt.bak"* ]]
  [[ "$result" != *"c.dat"* ]]
}

@test "find_file_expr returns all files when no patterns set" {
  echo "data" > "$TMPDIR/a.txt"
  echo "data" > "$TMPDIR/b.dat"
  result=$(find_file_expr "$TMPDIR" | tr '\0' '\n')
  [[ "$result" == *"a.txt"* ]]
  [[ "$result" == *"b.dat"* ]]
}

# --- has_files with INCLUDE_PATTERNS ---

@test "has_files returns 1 when only non-matching files exist with INCLUDE_PATTERNS" {
  echo "data" > "$TMPDIR/file.dat"
  INCLUDE_PATTERNS=("*.txt")
  run has_files "$TMPDIR"
  [ "$status" -eq 1 ]
}

@test "has_files returns 0 when matching file exists with INCLUDE_PATTERNS" {
  echo "data" > "$TMPDIR/file.txt"
  INCLUDE_PATTERNS=("*.txt")
  run has_files "$TMPDIR"
  [ "$status" -eq 0 ]
}

@test "has_files returns 0 with no INCLUDE_PATTERNS set" {
  echo "data" > "$TMPDIR/file.dat"
  run has_files "$TMPDIR"
  [ "$status" -eq 0 ]
}

# --- has_local_files with INCLUDE_PATTERNS ---

@test "has_local_files returns 1 when only non-matching files exist with INCLUDE_PATTERNS" {
  echo "data" > "$TMPDIR/file.dat"
  INCLUDE_PATTERNS=("*.txt")
  run has_local_files "$TMPDIR"
  [ "$status" -eq 1 ]
}

@test "has_local_files returns 0 when matching file exists with INCLUDE_PATTERNS" {
  echo "data" > "$TMPDIR/file.txt"
  INCLUDE_PATTERNS=("*.txt")
  run has_local_files "$TMPDIR"
  [ "$status" -eq 0 ]
}

# --- Integration: CLI flags via checksums.sh ---

@test "--exclude flag excludes matching files" {
  mkdir -p "$TMPDIR/dir"
  echo "keep" > "$TMPDIR/dir/a.txt"
  echo "skip" > "$TMPDIR/dir/b.tmp"
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" \
    --exclude '*.tmp' --allow-root-sidefiles -y "$TMPDIR/dir"
  [ "$status" -eq 0 ]
  # Manifest should contain a.txt but not b.tmp
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" == *"a.txt"* ]]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" != *"b.tmp"* ]]
}

@test "--include flag includes only matching files" {
  mkdir -p "$TMPDIR/dir"
  echo "keep" > "$TMPDIR/dir/a.txt"
  echo "skip" > "$TMPDIR/dir/b.dat"
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" \
    --include '*.txt' --allow-root-sidefiles -y "$TMPDIR/dir"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" == *"a.txt"* ]]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" != *"b.dat"* ]]
}

@test "-e short flag works same as --exclude" {
  mkdir -p "$TMPDIR/dir"
  echo "keep" > "$TMPDIR/dir/a.txt"
  echo "skip" > "$TMPDIR/dir/b.tmp"
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" \
    -e '*.tmp' --allow-root-sidefiles -y "$TMPDIR/dir"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" == *"a.txt"* ]]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" != *"b.tmp"* ]]
}

@test "-i short flag works same as --include" {
  mkdir -p "$TMPDIR/dir"
  echo "keep" > "$TMPDIR/dir/a.txt"
  echo "skip" > "$TMPDIR/dir/b.dat"
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" \
    -i '*.txt' --allow-root-sidefiles -y "$TMPDIR/dir"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" == *"a.txt"* ]]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" != *"b.dat"* ]]
}

@test "--exclude supports comma-separated patterns" {
  mkdir -p "$TMPDIR/dir"
  echo "keep" > "$TMPDIR/dir/a.txt"
  echo "skip1" > "$TMPDIR/dir/b.tmp"
  echo "skip2" > "$TMPDIR/dir/c.bak"
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" \
    --exclude '*.tmp,*.bak' --allow-root-sidefiles -y "$TMPDIR/dir"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" == *"a.txt"* ]]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" != *"b.tmp"* ]]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" != *"c.bak"* ]]
}

@test "--exclude is repeatable" {
  mkdir -p "$TMPDIR/dir"
  echo "keep" > "$TMPDIR/dir/a.txt"
  echo "skip1" > "$TMPDIR/dir/b.tmp"
  echo "skip2" > "$TMPDIR/dir/c.bak"
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" \
    -e '*.tmp' -e '*.bak' --allow-root-sidefiles -y "$TMPDIR/dir"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" == *"a.txt"* ]]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" != *"b.tmp"* ]]
  [[ "$(cat "$TMPDIR/dir/#####checksums#####.md5")" != *"c.bak"* ]]
}

# --- Edge cases ---

@test "--include '*.md5' does not include tool-generated .md5 file" {
  # Tool files must always be excluded even if include pattern matches them
  mkdir -p "$TMPDIR/dir"
  echo "data" > "$TMPDIR/dir/userfile.md5"
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" \
    --include '*.md5' --allow-root-sidefiles -y "$TMPDIR/dir"
  [ "$status" -eq 0 ]
  local manifest="$TMPDIR/dir/#####checksums#####.md5"
  # User's .md5 file should be included
  [[ "$(cat "$manifest")" == *"userfile.md5"* ]]
  # Tool-generated manifest must NOT reference itself
  [[ "$(cat "$manifest")" != *"#####checksums#####.md5"* ]]
}

@test "config and CLI exclude patterns accumulate" {
  mkdir -p "$TMPDIR/dir"
  echo "keep" > "$TMPDIR/dir/a.txt"
  echo "skip1" > "$TMPDIR/dir/b.tmp"
  echo "skip2" > "$TMPDIR/dir/c.bak"
  # Config excludes *.tmp, CLI excludes *.bak — both should be excluded
  printf 'EXCLUDE_PATTERNS=*.tmp\n' > "$TMPDIR/dir/#####checksums#####.conf"
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" \
    --exclude '*.bak' --allow-root-sidefiles -y "$TMPDIR/dir"
  [ "$status" -eq 0 ]
  local manifest="$TMPDIR/dir/#####checksums#####.md5"
  [[ "$(cat "$manifest")" == *"a.txt"* ]]
  [[ "$(cat "$manifest")" != *"b.tmp"* ]]
  [[ "$(cat "$manifest")" != *"c.bak"* ]]
}

@test "--exclude handles filenames with spaces" {
  mkdir -p "$TMPDIR/dir"
  echo "keep" > "$TMPDIR/dir/my file.txt"
  echo "skip" > "$TMPDIR/dir/my file.tmp"
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" \
    --exclude '*.tmp' --allow-root-sidefiles -y "$TMPDIR/dir"
  [ "$status" -eq 0 ]
  local manifest="$TMPDIR/dir/#####checksums#####.md5"
  [[ "$(cat "$manifest")" == *"my file.txt"* ]]
  [[ "$(cat "$manifest")" != *"my file.tmp"* ]]
}
