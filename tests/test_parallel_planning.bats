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
  RUN_LOG="$TMPDIR/run.log"
  : > "$RUN_LOG"
  TARGET_DIR="$TMPDIR"
  export VERIFY_MD5_DETAILS=0
  unset NO_ROOT_SIDEFILES

  detect_stat

  # Create several directories with files
  for i in 1 2 3 4; do
    mkdir -p "$TMPDIR/dir$i"
    echo "content $i" > "$TMPDIR/dir$i/file.txt"
  done
}

teardown() { rm -rf "$TMPDIR"; }

@test "parallel planning produces same plan as sequential (new dirs)" {
  # Sequential
  PARALLEL_JOBS=1
  local seq_proc="$TMPDIR/seq.proc" seq_skip="$TMPDIR/seq.skip"
  decide_directories_plan "$TMPDIR" "$seq_proc" "$seq_skip"
  local seq_proc_list seq_skip_list
  seq_proc_list=$(tr '\0' '\n' < "$seq_proc" | sort)
  seq_skip_list=$(tr '\0' '\n' < "$seq_skip" | sort)

  # Parallel
  PARALLEL_JOBS=4
  local par_proc="$TMPDIR/par.proc" par_skip="$TMPDIR/par.skip"
  decide_directories_plan "$TMPDIR" "$par_proc" "$par_skip"
  local par_proc_list par_skip_list
  par_proc_list=$(tr '\0' '\n' < "$par_proc" | sort)
  par_skip_list=$(tr '\0' '\n' < "$par_skip" | sort)

  [ "$seq_proc_list" = "$par_proc_list" ]
  [ "$seq_skip_list" = "$par_skip_list" ]
}

@test "parallel planning produces same plan with existing manifests" {
  # Process all directories to create manifests
  PARALLEL_JOBS=1
  for i in 1 2 3 4; do
    process_single_directory "$TMPDIR/dir$i"
  done

  # Modify one directory so it needs reprocessing
  echo "changed" > "$TMPDIR/dir2/file.txt"

  # Sequential
  local seq_proc="$TMPDIR/seq.proc" seq_skip="$TMPDIR/seq.skip"
  decide_directories_plan "$TMPDIR" "$seq_proc" "$seq_skip"
  local seq_proc_list seq_skip_list
  seq_proc_list=$(tr '\0' '\n' < "$seq_proc" | sort)
  seq_skip_list=$(tr '\0' '\n' < "$seq_skip" | sort)

  # Parallel
  PARALLEL_JOBS=4
  local par_proc="$TMPDIR/par.proc" par_skip="$TMPDIR/par.skip"
  decide_directories_plan "$TMPDIR" "$par_proc" "$par_skip"
  local par_proc_list par_skip_list
  par_proc_list=$(tr '\0' '\n' < "$par_proc" | sort)
  par_skip_list=$(tr '\0' '\n' < "$par_skip" | sort)

  [ "$seq_proc_list" = "$par_proc_list" ]
  [ "$seq_skip_list" = "$par_skip_list" ]
}

@test "parallel planning handles empty directories correctly" {
  SKIP_EMPTY=1
  mkdir -p "$TMPDIR/empty_dir"

  PARALLEL_JOBS=4
  local proc="$TMPDIR/proc" skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$proc" "$skip"

  # Empty dir should be skipped
  local skipped
  skipped=$(tr '\0' '\n' < "$skip")
  echo "$skipped" | grep -q "empty_dir"
}

@test "parallel planning cleans up temp directory" {
  PARALLEL_JOBS=4
  local proc="$TMPDIR/proc" skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$proc" "$skip"

  # No leftover plan_par temp dirs
  local leftovers
  leftovers=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'plan_par.*' 2>/dev/null | wc -l)
  [ "$leftovers" -eq 0 ]
}

@test "parallel planning preserves directory order" {
  PARALLEL_JOBS=4
  local proc="$TMPDIR/proc" skip="$TMPDIR/skip"
  decide_directories_plan "$TMPDIR" "$proc" "$skip"

  # The to-process list should be in sorted order (matching find|sort)
  local proc_list sorted_list
  proc_list=$(tr '\0' '\n' < "$proc" | grep -v '^$')
  sorted_list=$(echo "$proc_list" | LC_ALL=C sort)

  [ "$proc_list" = "$sorted_list" ]
}
