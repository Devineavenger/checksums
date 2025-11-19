#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/fs.sh'
load '../lib/planner.sh'
load '../lib/meta.sh'
load '../lib/hash.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
}
teardown() { rm -rf "$TMPDIR"; }

@test "decide_quick_plan skips hidden files" {
  echo "data" > "$TMPDIR/.hiddenfile"
  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_quick_plan "$TMPDIR" "$out_proc" "$out_skip"
  tr '\0' '\n' < "$out_skip" | grep -q ".hiddenfile"
}

@test "decide_directories_plan skips dir with valid meta" {
  mkdir "$TMPDIR/dir"
  echo "foo" > "$TMPDIR/dir/file.txt"
  md5=$(file_hash "$TMPDIR/dir/file.txt" md5)
  printf '%s  ./file.txt\n' "$md5" > "$TMPDIR/dir/$MD5_FILENAME"
  line="file.txt\t1\t1\t$(stat -c %Y "$TMPDIR/dir/file.txt")\t$(stat -c %s "$TMPDIR/dir/file.txt")\t$md5"
  write_meta "$TMPDIR/dir/$META_FILENAME" "$line"
  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$out_proc" "$out_skip"
  tr '\0' '\n' < "$out_skip" | grep -q "$TMPDIR/dir"
}

@test "decide_directories_plan schedules dir when filecount mismatch" {
  mkdir "$TMPDIR/dir"
  echo "foo" > "$TMPDIR/dir/file.txt"
  echo "bar" > "$TMPDIR/dir/file2.txt"
  md5=$(file_hash "$TMPDIR/dir/file.txt" md5)
  printf '%s  ./file.txt\n' "$md5" > "$TMPDIR/dir/$MD5_FILENAME"
  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$out_proc" "$out_skip"
  tr '\0' '\n' < "$out_proc" | grep -q "$TMPDIR/dir"
}
