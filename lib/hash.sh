#!/usr/bin/env bash
# hash.sh
#
# Hashing helpers and a portable parallel job controller.
#
# Responsibilities:
#  - file_hash: compute md5 or sha256 in a portable way (GNU coreutils or BSD tools)
#  - parallel job management: spawn background hash workers up to PARALLEL_JOBS
#  - collect and write results into a temporary results file for the main process
#
# Notes:
#  - We avoid using wait -n for portability; instead we implement a small FIFO
#    of PIDs and wait for the earliest to finish when we hit the job limit.
#  - The results file format is "path<TAB>hash\n" to be safely parsed by the parent.

file_hash() {
  local f="$1" algo="$2"
  if [ "$algo" = "md5" ]; then
    if command -v md5sum >/dev/null 2>&1; then
      md5sum --binary -- "$f" 2>/dev/null | awk '{print $1}'
    else
      md5 -r -- "$f" 2>/dev/null | awk '{print $1}'
    fi
  else
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum --binary -- "$f" 2>/dev/null | awk '{print $1}'
    else
      shasum -a 256 -- "$f" 2>/dev/null | awk '{print $1}'
    fi
  fi
}

# Parallel job control state (namespaced to avoid collisions)
HASH_PIDS=()
HASH_PIDS_COUNT=0

_par_wait_one() {
  # Wait for the oldest background PID in our queue
  local pid="${HASH_PIDS[0]}"
  if [ -n "$pid" ]; then
    wait "$pid" 2>/dev/null || true
    HASH_PIDS=("${HASH_PIDS[@]:1}")
    HASH_PIDS_COUNT=${#HASH_PIDS[@]}
   fi
}

_par_maybe_wait() {
  # If we have reached PARALLEL_JOBS in-flight, wait for one to finish.
  while [ "${HASH_PIDS_COUNT:-0}" -ge "$PARALLEL_JOBS" ]; do _par_wait_one; done
}

_par_wait_all() {
  # Wait for all outstanding workers to finish before proceeding.
  if [ "${#HASH_PIDS[@]}" -gt 0 ]; then
    for pid in "${HASH_PIDS[@]}"; do
      [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
  fi
  HASH_PIDS=()
  HASH_PIDS_COUNT=0
}

_do_hash_task() {
  # Worker invoked in background: compute hash and append to results file.
  local path="$1" algo="$2" results_file="$3"
  local h
  h=$(file_hash "$path" "$algo") || h=""
  printf '%s\t%s\n' "$path" "$h" >> "$results_file"
}
