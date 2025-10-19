#!/usr/bin/env bash
# hash.sh
# Hashing helpers + portable parallel job control without wait -n.

file_hash() {
  local f="$1" algo="$2"
  if [ "$algo" = "md5" ]; then
    if command -v md5sum >/dev/null 2>&1; then md5sum --binary -- "$f" 2>/dev/null | awk '{print $1}'
    else md5 -r -- "$f" 2>/dev/null | awk '{print $1}'; fi
  else
    if command -v sha256sum >/dev/null 2>&1; then sha256sum --binary -- "$f" 2>/dev/null | awk '{print $1}'
    else shasum -a 256 -- "$f" 2>/dev/null | awk '{print $1}'; fi
  fi
}

# Parallel job control helpers (portable, no wait -n)
pids=()
pids_count=0
_par_wait_one() {
  local pid="${pids[0]}"
  if [ -n "$pid" ]; then
    wait "$pid" 2>/dev/null || true
    pids=("${pids[@]:1}")
    pids_count=${#pids[@]}
  fi
}
_par_maybe_wait() {
  while [ "$pids_count" -ge "$PARALLEL_JOBS" ]; do _par_wait_one; done
}
_par_wait_all() {
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  pids=()
  pids_count=0
}

_do_hash_task() {
  local path="$1" algo="$2" results_file="$3"
  local h
  h=$(file_hash "$path" "$algo") || h=""
  printf '%s\t%s\n' "$path" "$h" >> "$results_file"
}
