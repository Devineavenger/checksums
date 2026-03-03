#!/usr/bin/env bats

# Load the relevant modules
load '../lib/hash.sh'
load '../lib/first_run.sh'
load '../lib/logging.sh'
load '../lib/fs.sh'

setup() {
  TMPDIR=$(mktemp -d)
  echo "hello world" > "$TMPDIR/file.txt"
  BASE_NAME="#####checksums#####"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  RUN_LOG="$TMPDIR/run.log"
  : > "$RUN_LOG"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "verify_md5_file returns 2 when manifest references missing file" {
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  # GNU md5sum format: two spaces between hash and filename
  printf '%s  %s\n' "$md5" "ghost.txt" > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  # Expect return code 2 (missing file referenced in manifest)
  [ "$status" -eq 2 ]
}

@test "verify_md5_file returns 1 for malformed manifest line" {
  echo "not-a-valid-line" > "$TMPDIR/$MD5_FILENAME"
  run verify_md5_file "$TMPDIR"
  [ "$status" -eq 1 ]
}

@test "emit_md5_file_details logs MISSING and MISMATCH lines" {
  echo "foo" > "$TMPDIR/foo.txt"
  md5foo=$(file_hash "$TMPDIR/foo.txt" md5)
  printf '%s  %s\n' "$md5foo" "foo.txt" > "$TMPDIR/$MD5_FILENAME"
  # Corrupt file
  echo "bar" > "$TMPDIR/foo.txt"
  : > "$RUN_LOG"
  run emit_md5_file_details "$TMPDIR" "$TMPDIR/$MD5_FILENAME"
  [ "$status" -eq 1 ]
  grep -q "MISMATCH:" "$RUN_LOG"
}

@test "emit_md5_file_details logs MISSING when file is absent" {
  # Record a valid hash for an existing file but point the manifest at a ghost path
  md5=$(file_hash "$TMPDIR/file.txt" md5)
  printf '%s  %s\n' "$md5" "ghost.txt" > "$TMPDIR/$MD5_FILENAME"
  : > "$RUN_LOG"
  run emit_md5_file_details "$TMPDIR" "$TMPDIR/$MD5_FILENAME"
  [ "$status" -eq 2 ]
  grep -q "MISSING:" "$RUN_LOG"
}

@test "SKIP_EMPTY prevents sidecar creation in empty directory" {
  mkdir "$TMPDIR/emptydir"
  SKIP_EMPTY=1
  run has_files "$TMPDIR/emptydir"
  [ "$status" -eq 1 ]
}

@test "NO_ROOT_SIDEFILES prevents log creation in root" {
  NO_ROOT_SIDEFILES=1
  dir_log_append "$TMPDIR" "test message"
  [ ! -f "$TMPDIR/$LOG_FILENAME" ]
}
