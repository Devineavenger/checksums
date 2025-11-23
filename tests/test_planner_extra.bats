#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/fs.sh'
load '../lib/planner.sh'
load '../lib/meta.sh'
load '../lib/hash.sh'
load '../lib/logging.sh'
load '../lib/process.sh'
load '../lib/stat.sh'
load '../lib/compat.sh'

setup() {
  TMPDIR=$(mktemp -d)
  BASE_NAME="#####checksums#####"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"

  # create a dummy run log so emit_md5_detail has somewhere to write
  RUN_LOG="$TMPDIR/run.log"
  : > "$RUN_LOG"
  
  # avoid planner forcing md5 detail re-checks during tests
  # ensure tests use same sidefile behaviour as planner expects
  unset NO_ROOT_SIDEFILES
  export VERIFY_MD5_DETAILS=0

  # prepare a directory with a valid meta before each test
  mkdir "$TMPDIR/dir"
  echo "foo" > "$TMPDIR/dir/file.txt"
  TARGET_DIR="$TMPDIR"
  # set mtime to current time before processing so meta and file agree
  touch "$TMPDIR/dir/file.txt"
  process_single_directory "$TMPDIR/dir"
}

teardown() { rm -rf "$TMPDIR"; }

@test "decide_quick_plan skips hidden files" {
  mkdir "$TMPDIR/.hiddendir"
  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_quick_plan "$TMPDIR" "$out_proc" "$out_skip"
  tr '\0' '\n' < "$out_skip" | grep -q "$TMPDIR/.hiddendir"
}

@test "decide_directories_plan skips dir with valid meta" {
  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$out_proc" "$out_skip"

  # assert directory is not in process list
  tr '\0' '\n' < "$out_proc" | grep -vq "$TMPDIR/dir"
}

@test "decide_directories_plan schedules dir when filecount mismatch" {
  rm -rf "$TMPDIR/dir"        # remove the one created in setup
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
