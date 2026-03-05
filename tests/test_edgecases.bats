#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/meta.sh'
load '../lib/fs.sh'
load '../lib/hash.sh'
load '../lib/orchestrator.sh'
load '../lib/process.sh'

setup() {
  TMPDIR=$(mktemp -d)

  BASE_NAME="#####checksums#####"
  SUM_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_FILENAME="${BASE_NAME}.log"
}

teardown() { rm -rf "$TMPDIR"; }

@test "verify_meta_sig passes when no signature line is present (unsigned meta)" {
  metaf="$TMPDIR/$META_FILENAME"
  echo "#meta   v1  2025-01-01T00:00:00Z" > "$metaf"
  run verify_meta_sig "$metaf"
  [ "$status" -eq 0 ]
}

@test "has_files skips rotated logs" {
  touch "$TMPDIR/${BASE_NAME}.20250101.log"
  run has_files "$TMPDIR"
  [ "$status" -eq 1 ]
}

@test "cleanup_leftover_locks removes stale lock" {
  lf="$TMPDIR/$META_FILENAME.lock"
  : > "$lf"
  run cleanup_leftover_locks "$TMPDIR"
  [ ! -f "$lf" ]
}

@test "classify_batch_size respects thresholds" {
  BATCH_RULES="0-1M:20,1M-80M:5,>80M:1"
  init_batch_thresholds

  # If associative arrays are available (normal on Bash 4+)
  if declare -p -A >/dev/null 2>&1; then
    for k in "${!BATCH_THRESHOLDS[@]}"; do
      printf 'THRESH: %s -> %s\n' "$k" "${BATCH_THRESHOLDS[$k]}"
    done
  else
    # fallback string list (if your code uses THRESHOLDS_LIST)
    printf '%s\n' "$THRESHOLDS_LIST"
  fi

  [ "$(classify_batch_size 500000)" -eq 20 ]
  [ "$(classify_batch_size 2000000)" -eq 5 ]
  [ "$(classify_batch_size 100000000)" -eq 1 ]
}

#@test "debug: dump thresholds" {
#  BATCH_RULES="0-1M:20,1M-80M:5,>80M:1"
#  init_batch_thresholds
#
#  if declare -p -A >/dev/null 2>&1; then
#    for k in "${!BATCH_THRESHOLDS[@]}"; do
#      printf '%s -> %s\n' "$k" "${BATCH_THRESHOLDS[$k]}"
#    done
#  else
#    printf '%s\n' "$THRESHOLDS_LIST"
#  fi
#
#  # temporary: fail so output is shown; remove or change to assertions when done
#  false
#}

@test "_orch_cleanup removes registered temp files" {
  local f1 f2
  f1="$(mktemp "$TMPDIR/orch_tmp.XXXXXX")"
  f2="$(mktemp "$TMPDIR/orch_tmp.XXXXXX")"
  _ORCH_TMPFILES=()
  _ORCH_TMPDIRS=()
  _orch_register_tmp "$f1"
  _orch_register_tmp "$f2"
  [ -f "$f1" ]
  [ -f "$f2" ]
  _orch_cleanup
  [ ! -f "$f1" ]
  [ ! -f "$f2" ]
}

@test "_orch_cleanup removes registered temp directories" {
  local d1
  d1="$(mktemp -d "$TMPDIR/orch_dir.XXXXXX")"
  touch "$d1/somefile"
  _ORCH_TMPFILES=()
  _ORCH_TMPDIRS=()
  _orch_register_tmpd "$d1"
  [ -d "$d1" ]
  _orch_cleanup
  [ ! -d "$d1" ]
}

@test "_orch_cleanup destroys active semaphore" {
  PARALLEL_JOBS=2
  _ORCH_TMPFILES=()
  _ORCH_TMPDIRS=()
  _sem_init
  local fifo="$SEM_FIFO"
  [ -p "$fifo" ]
  [ -n "$SEM_FD" ]
  _orch_cleanup
  [ ! -e "$fifo" ]
  [ -z "$SEM_FD" ]
}

@test "_orch_cleanup is safe to call with nothing registered" {
  _ORCH_TMPFILES=()
  _ORCH_TMPDIRS=()
  SEM_FD=""
  SEM_FIFO=""
  run _orch_cleanup
  [ "$status" -eq 0 ]
}
