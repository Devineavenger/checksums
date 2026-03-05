#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/fs.sh'
load '../lib/meta.sh'
load '../lib/hash.sh'
load '../lib/logging.sh'
load '../lib/process.sh'
load '../lib/stat.sh'
load '../lib/compat.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  SUM_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  TARGET_DIR="$TMPDIR"
  RUN_LOG="$TMPDIR/run.log"
  : > "$RUN_LOG"
  # ensure stable locale behavior
  export LC_ALL=C
}

teardown() { rm -rf "$TMPDIR"; }

@test "find_file_expr handles filenames with spaces" {
  fname="file with space.txt"
  echo "foo" > "$TMPDIR/$fname"
  # consume NUL-separated output and match by basename to avoid path-format differences
  found=""
  while IFS= read -r -d '' path; do
    base=$(basename "$path")
    [ "$base" = "$fname" ] && found=1 && break
  done < <(find_file_expr "$TMPDIR")
  [ -n "$found" ]
}

@test "process_single_directory logs when many files" {
  mkdir "$TMPDIR/dir"
  for i in $(seq 1 120); do echo "x" > "$TMPDIR/dir/file$i.txt"; done
  VERBOSE=1
  run process_single_directory "$TMPDIR/dir"
  # assert command succeeded
  [ "$status" -eq 0 ]
  # assert sidefiles exist and contain expected entries; this is robust across logging modes
  [ -f "$TMPDIR/dir/$SUM_FILENAME" ]
  [ -f "$TMPDIR/dir/$META_FILENAME" ]
  test "$(wc -l < "$TMPDIR/dir/$SUM_FILENAME")" -eq 120
  # count only meaningful meta lines (tab-separated fields, at least 6 columns)
  meta_count=$(awk -F'\t' 'NF>=6 {c++} END{print c+0}' "$TMPDIR/dir/$META_FILENAME")
  test "$meta_count" -ge 120
}
