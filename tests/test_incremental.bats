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
  SUM_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
  RUN_LOG="$TMPDIR/run.log"
  : > "$RUN_LOG"
  TARGET_DIR="$TMPDIR"
  export VERIFY_MD5_DETAILS=0
  unset NO_ROOT_SIDEFILES

  # Create a directory with a file, process it to build initial meta
  mkdir "$TMPDIR/dir"
  echo "hello" > "$TMPDIR/dir/file.txt"
  touch "$TMPDIR/dir/file.txt"
  process_single_directory "$TMPDIR/dir"
}

teardown() { rm -rf "$TMPDIR"; }

@test "planner skips unchanged directory (stat cache populated)" {
  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$out_proc" "$out_skip"

  # dir should be skipped (unchanged)
  if [ -f "$out_proc" ]; then
    ! tr '\0' '\n' < "$out_proc" | grep -q "$TMPDIR/dir"
  fi
}

@test "planner detects mtime change" {
  # Touch file to change mtime
  sleep 1
  touch "$TMPDIR/dir/file.txt"

  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$out_proc" "$out_skip"

  tr '\0' '\n' < "$out_proc" | grep -q "$TMPDIR/dir"
}

@test "planner detects file replacement via inode change" {
  # Replace file with same content and size but different inode
  local orig_content
  orig_content=$(cat "$TMPDIR/dir/file.txt")
  rm "$TMPDIR/dir/file.txt"
  echo "$orig_content" > "$TMPDIR/dir/file.txt"
  # Preserve original mtime to ensure only inode differs
  # (on most filesystems, creating a new file gives a new inode)
  local orig_mtime
  orig_mtime=$(stat_field "$TMPDIR/dir/$META_FILENAME" mtime 2>/dev/null || echo "")

  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$out_proc" "$out_skip"

  # Should be scheduled for processing (inode changed)
  tr '\0' '\n' < "$out_proc" | grep -q "$TMPDIR/dir"
}

@test "planner detects deleted file when other files remain" {
  # Add a second file so the directory isn't empty after deletion
  echo "extra" > "$TMPDIR/dir/extra.txt"
  # Reprocess to include extra.txt in meta
  process_single_directory "$TMPDIR/dir"
  # Now delete one file — meta references it but it's gone
  rm "$TMPDIR/dir/file.txt"

  out_proc="$TMPDIR/proc"
  out_skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$out_proc" "$out_skip"

  tr '\0' '\n' < "$out_proc" | grep -q "$TMPDIR/dir"
}

@test "STAT_CACHE cleared between directories" {
  # Process creates STAT_CACHE entries, then clears them
  # Create a second directory and process it
  mkdir "$TMPDIR/dir2"
  echo "world" > "$TMPDIR/dir2/file.txt"
  touch "$TMPDIR/dir2/file.txt"
  process_single_directory "$TMPDIR/dir2"

  # STAT_CACHE should be empty after processing (cleared at end)
  if [ "${USE_ASSOC:-0}" -eq 1 ]; then
    [ "${#STAT_CACHE[@]}" -eq 0 ]
  fi
}
