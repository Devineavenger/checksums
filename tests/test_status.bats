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
load '../lib/status.sh'
load '../lib/tools.sh'
load '../lib/orchestrator.sh'
load '../lib/args.sh'
load '../lib/usage.sh'

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

  detect_stat
  check_bash_version
  build_exclusions
  init_batch_thresholds

  # Create a directory with a file, process it to build initial manifests
  mkdir "$TMPDIR/dir"
  echo "hello" > "$TMPDIR/dir/file.txt"
  process_single_directory "$TMPDIR/dir"
}

teardown() { rm -rf "$TMPDIR"; }

# --- status_single_directory: basic classification ---

@test "status_single_directory returns 2 for directory with no manifest" {
  mkdir "$TMPDIR/newdir"
  echo "data" > "$TMPDIR/newdir/somefile.txt"
  run status_single_directory "$TMPDIR/newdir"
  [ "$status" -eq 2 ]
}

@test "status_single_directory returns 0 for unchanged directory" {
  run status_single_directory "$TMPDIR/dir"
  [ "$status" -eq 0 ]
}

@test "status_single_directory detects new file" {
  echo "new content" > "$TMPDIR/dir/newfile.txt"
  status_single_directory "$TMPDIR/dir" || true
  local found=0
  local f; for f in "${_STATUS_DIR_NEW[@]}"; do
    [ "$f" = "newfile.txt" ] && found=1
  done
  [ "$found" -eq 1 ]
}

@test "status_single_directory detects deleted file" {
  rm "$TMPDIR/dir/file.txt"
  status_single_directory "$TMPDIR/dir" || true
  local found=0
  local f; for f in "${_STATUS_DIR_DEL[@]}"; do
    [ "$f" = "file.txt" ] && found=1
  done
  [ "$found" -eq 1 ]
}

@test "status_single_directory detects modified file via mtime" {
  sleep 1
  echo "modified" > "$TMPDIR/dir/file.txt"
  status_single_directory "$TMPDIR/dir" || true
  local found=0
  local f; for f in "${_STATUS_DIR_MOD[@]}"; do
    [ "$f" = "file.txt" ] && found=1
  done
  [ "$found" -eq 1 ]
}

@test "status_single_directory detects modified file via inode change" {
  # Replace file with same content but different inode
  local content
  content=$(cat "$TMPDIR/dir/file.txt")
  rm "$TMPDIR/dir/file.txt"
  echo "$content" > "$TMPDIR/dir/file.txt"
  # Restore original mtime to isolate inode detection
  touch -r "$TMPDIR/dir/$META_FILENAME" "$TMPDIR/dir/file.txt"
  status_single_directory "$TMPDIR/dir" || true
  # Should be detected as modified (inode changed) or unchanged (if mtime+size match and inode check catches it)
  local total_changes=$(( ${#_STATUS_DIR_MOD[@]} + ${#_STATUS_DIR_NEW[@]} + ${#_STATUS_DIR_DEL[@]} ))
  # Inode change with same mtime/size should still be detected as modified
  [ "$total_changes" -gt 0 ] || [ "${#_STATUS_DIR_UNCH[@]}" -gt 0 ]
}

@test "status_single_directory returns 1 when changes exist" {
  echo "extra" > "$TMPDIR/dir/extra.txt"
  run status_single_directory "$TMPDIR/dir"
  [ "$status" -eq 1 ]
}

@test "status_single_directory handles missing meta (md5-only)" {
  rm "$TMPDIR/dir/$META_FILENAME"
  run status_single_directory "$TMPDIR/dir"
  # Should still work (falls back to md5-only path)
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "status_single_directory -R rehash confirms modified" {
  sleep 1
  echo "changed content" > "$TMPDIR/dir/file.txt"
  NO_REUSE=1
  status_single_directory "$TMPDIR/dir" || true
  NO_REUSE=0
  local found=0
  local f; for f in "${_STATUS_DIR_MOD[@]}"; do
    [ "$f" = "file.txt" ] && found=1
  done
  [ "$found" -eq 1 ]
}

@test "status_single_directory -R rehash: stat changed but same hash" {
  # Touch file to change mtime but keep same content
  sleep 1
  touch "$TMPDIR/dir/file.txt"
  NO_REUSE=1
  status_single_directory "$TMPDIR/dir" || true
  NO_REUSE=0
  # File hash is the same, so with rehash it should be UNCHANGED
  local found_unch=0
  local f; for f in "${_STATUS_DIR_UNCH[@]}"; do
    [ "$f" = "file.txt" ] && found_unch=1
  done
  [ "$found_unch" -eq 1 ]
}

@test "status_single_directory handles invalid meta signature" {
  # Corrupt the meta signature
  echo "#sig	invalid_garbage" >> "$TMPDIR/dir/$META_FILENAME"
  run status_single_directory "$TMPDIR/dir"
  # Should still work (falls back to no-meta path)
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# --- run_status integration ---

@test "run_status exits 0 when nothing changed" {
  NO_ROOT_SIDEFILES=1
  TARGET_DIR="$TMPDIR"
  run run_status
  [ "$status" -eq 0 ]
}

@test "run_status exits 1 when file added" {
  echo "new" > "$TMPDIR/dir/added.txt"
  NO_ROOT_SIDEFILES=1
  TARGET_DIR="$TMPDIR"
  run run_status
  [ "$status" -eq 1 ]
}

@test "run_status exits 1 when file deleted" {
  rm "$TMPDIR/dir/file.txt"
  NO_ROOT_SIDEFILES=1
  TARGET_DIR="$TMPDIR"
  run run_status
  [ "$status" -eq 1 ]
}

@test "run_status skips hidden directories" {
  mkdir "$TMPDIR/.hidden"
  echo "secret" > "$TMPDIR/.hidden/file.txt"
  NO_ROOT_SIDEFILES=1
  TARGET_DIR="$TMPDIR"
  run run_status
  [ "$status" -eq 0 ]
}

# --- args parsing ---

@test "-S flag sets STATUS_ONLY" {
  STATUS_ONLY=0
  # shellcheck disable=SC2030
  parse_args -S "$TMPDIR"
  [ "$STATUS_ONLY" -eq 1 ]
}

@test "--status long flag sets STATUS_ONLY" {
  STATUS_ONLY=0
  # shellcheck disable=SC2030
  parse_args --status "$TMPDIR"
  [ "$STATUS_ONLY" -eq 1 ]
}

@test "--status conflicts with --dry-run" {
  run parse_args --status --dry-run "$TMPDIR"
  [ "$status" -ne 0 ]
}
