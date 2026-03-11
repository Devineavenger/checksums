#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/fs.sh'
load '../lib/planner.sh'
load '../lib/meta.sh'
load '../lib/hash.sh'
load '../lib/logging.sh'
load '../lib/verification.sh'
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
}

teardown() { rm -rf "$TMPDIR"; }

@test "parallel verify returns 0 for correct manifest" {
  mkdir "$TMPDIR/dir"
  echo "aaa" > "$TMPDIR/dir/a.txt"
  echo "bbb" > "$TMPDIR/dir/b.txt"
  echo "ccc" > "$TMPDIR/dir/c.txt"

  local ha hb hc
  ha=$(file_hash "$TMPDIR/dir/a.txt" md5)
  hb=$(file_hash "$TMPDIR/dir/b.txt" md5)
  hc=$(file_hash "$TMPDIR/dir/c.txt" md5)
  printf '%s  ./a.txt\n%s  ./b.txt\n%s  ./c.txt\n' "$ha" "$hb" "$hc" \
    > "$TMPDIR/dir/$SUM_FILENAME"

  PARALLEL_JOBS=2
  run emit_md5_file_details "$TMPDIR/dir" "$TMPDIR/dir/$SUM_FILENAME"
  [ "$status" -eq 0 ]
}

@test "parallel verify returns 1 on hash mismatch" {
  mkdir "$TMPDIR/dir"
  echo "aaa" > "$TMPDIR/dir/a.txt"
  echo "bbb" > "$TMPDIR/dir/b.txt"

  local ha hb
  ha=$(file_hash "$TMPDIR/dir/a.txt" md5)
  hb="0000000000000000000000000000dead"
  printf '%s  ./a.txt\n%s  ./b.txt\n' "$ha" "$hb" \
    > "$TMPDIR/dir/$SUM_FILENAME"

  PARALLEL_JOBS=2
  run emit_md5_file_details "$TMPDIR/dir" "$TMPDIR/dir/$SUM_FILENAME"
  [ "$status" -eq 1 ]
  grep -q "MISMATCH" "$RUN_LOG"
}

@test "parallel verify returns 2 on missing file" {
  mkdir "$TMPDIR/dir"
  echo "aaa" > "$TMPDIR/dir/a.txt"
  local ha
  ha=$(file_hash "$TMPDIR/dir/a.txt" md5)
  printf '%s  ./a.txt\n%s  ./gone.txt\n' "$ha" "deadbeef" \
    > "$TMPDIR/dir/$SUM_FILENAME"

  PARALLEL_JOBS=2
  run emit_md5_file_details "$TMPDIR/dir" "$TMPDIR/dir/$SUM_FILENAME"
  [ "$status" -eq 2 ]
  grep -q "MISSING" "$RUN_LOG"
}

@test "sequential verify matches parallel verify results" {
  mkdir "$TMPDIR/dir"
  for i in $(seq 1 10); do
    echo "file content $i" > "$TMPDIR/dir/f${i}.txt"
  done

  # Build correct manifest
  local md5f="$TMPDIR/dir/$SUM_FILENAME"
  : > "$md5f"
  for i in $(seq 1 10); do
    h=$(file_hash "$TMPDIR/dir/f${i}.txt" md5)
    printf '%s  ./f%s.txt\n' "$h" "$i" >> "$md5f"
  done

  # Corrupt one entry
  sed -i '5s/^[a-f0-9]*/0000000000000000000000000000dead/' "$md5f"

  # Sequential
  PARALLEL_JOBS=1
  RUN_LOG="$TMPDIR/seq.log"; : > "$RUN_LOG"
  run emit_md5_file_details "$TMPDIR/dir" "$md5f"
  local seq_rc=$status

  # Parallel
  PARALLEL_JOBS=4
  RUN_LOG="$TMPDIR/par.log"; : > "$RUN_LOG"
  run emit_md5_file_details "$TMPDIR/dir" "$md5f"
  local par_rc=$status

  [ "$seq_rc" -eq "$par_rc" ]
  # Both should report exactly one MISMATCH
  [ "$(grep -c MISMATCH "$TMPDIR/seq.log")" -eq 1 ]
  [ "$(grep -c MISMATCH "$TMPDIR/par.log")" -eq 1 ]
}

@test "parallel verify cleans up temp directory" {
  mkdir "$TMPDIR/dir"
  echo "data" > "$TMPDIR/dir/file.txt"
  local h
  h=$(file_hash "$TMPDIR/dir/file.txt" md5)
  printf '%s  ./file.txt\n' "$h" > "$TMPDIR/dir/$SUM_FILENAME"

  PARALLEL_JOBS=2
  run emit_md5_file_details "$TMPDIR/dir" "$TMPDIR/dir/$SUM_FILENAME"
  [ "$status" -eq 0 ]
  # No verify.* temp dirs should remain
  [ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'verify.*' 2>/dev/null)" ]
}
