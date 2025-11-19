#!/usr/bin/env bats
load '../lib/fs.sh'
load '../lib/process.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  TARGET_DIR="$TMPDIR"
}
teardown() { rm -rf "$TMPDIR"; }

@test "find_file_expr handles filenames with spaces" {
  fname="file with space.txt"
  echo "foo" > "$TMPDIR/$fname"
  result=$(find_file_expr "$TMPDIR" | tr '\0' '\n')
  echo "$result" | grep -q "$fname"
}

@test "process_single_directory logs when many files" {
  for i in $(seq 1 120); do echo "x" > "$TMPDIR/file$i.txt"; done
  VERBOSE=1
  run process_single_directory "$TMPDIR"
  grep -q "has 120 files" "$TMPDIR/$LOG_FILENAME"
}
