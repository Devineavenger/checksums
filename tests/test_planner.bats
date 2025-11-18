#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/fs.sh'
load '../lib/planner.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "decide_quick_plan skips hidden dirs" {
  mkdir "$TMPDIR/.hidden"
  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_quick_plan "$TMPDIR" "$out_proc" "$out_skip"
  tr '\0' '\n' < "$out_skip" | grep -q "$TMPDIR/.hidden"
}

@test "decide_directories_plan schedules dir with no sumfile" {
  mkdir "$TMPDIR/dir"
  echo "data" > "$TMPDIR/dir/file.txt"
  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$out_proc" "$out_skip"
  tr '\0' '\n' < "$out_proc" | grep -q "$TMPDIR/dir"
}
