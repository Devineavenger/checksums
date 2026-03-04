#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

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
      md5sum --binary -- "$f" 2>/dev/null | cut -d' ' -f1
    else
      md5 -r -- "$f" 2>/dev/null | cut -d' ' -f1
    fi
  else
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum --binary -- "$f" 2>/dev/null | cut -d' ' -f1
    else
      shasum -a 256 -- "$f" 2>/dev/null | cut -d' ' -f1
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
  # When semaphore is active (parallel dirs), acquire a token instead of
  # PID-based throttling. The token blocks until a worker slot is available.
  if [ -n "${SEM_FD:-}" ]; then
    _sem_acquire
    return
  fi
  # Standard PID-based throttling for single-directory mode.
  while [ "${HASH_PIDS_COUNT:-0}" -ge "$PARALLEL_JOBS" ]; do _par_wait_one; done
}

_par_wait_all() {
  # Wait for all outstanding workers to finish before proceeding.
  if [ "${#HASH_PIDS[@]}" -gt 0 ]; then
    for pid in "${HASH_PIDS[@]}"; do
      if [ -n "$pid" ]; then
        wait "$pid" 2>/dev/null || true
      fi
    done
  fi
  HASH_PIDS=()
  HASH_PIDS_COUNT=0
}

# Directory-level parallel dispatch (separate PID pool from HASH_PIDS)
DIR_PIDS=()
DIR_PIDS_COUNT=0

_dir_par_wait_one() {
  local pid="${DIR_PIDS[0]}"
  if [ -n "$pid" ]; then
    wait "$pid" 2>/dev/null || true
    DIR_PIDS=("${DIR_PIDS[@]:1}")
    DIR_PIDS_COUNT=${#DIR_PIDS[@]}
  fi
}

_dir_par_maybe_wait() {
  while [ "${DIR_PIDS_COUNT:-0}" -ge "${PARALLEL_DIRS:-1}" ]; do _dir_par_wait_one; done
}

_dir_par_wait_all() {
  if [ "${#DIR_PIDS[@]}" -gt 0 ]; then
    for pid in "${DIR_PIDS[@]}"; do
      [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
  fi
  DIR_PIDS=()
  DIR_PIDS_COUNT=0
}

# === FIFO semaphore for shared worker pool across parallel directories ===
# When PARALLEL_DIRS > 1, all directories share a single pool of PARALLEL_JOBS
# hash worker slots. The semaphore is a named pipe filled with tokens.

_sem_init() {
  SEM_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/checksums_sem.XXXXXX")"
  mkfifo "$SEM_FIFO"
  eval "exec 7<>\"$SEM_FIFO\""
  SEM_FD=7
  local i
  for ((i=0; i<PARALLEL_JOBS; i++)); do printf 'x' >&7; done
}

_sem_destroy() {
  if [ -n "${SEM_FD:-}" ]; then
    eval "exec 7>&-" 2>/dev/null || true
  fi
  [ -n "${SEM_FIFO:-}" ] && rm -f "$SEM_FIFO" 2>/dev/null || true
  SEM_FD=""
  SEM_FIFO=""
}

_sem_acquire() {
  local _tok
  read -n 1 _tok <&7
}

_sem_release() {
  printf 'x' >&7
}

_do_hash_task() {
  # Worker invoked in background: compute hash and append to results file.
  local path="$1" algo="$2" results_file="$3"
  local h
  h=$(file_hash "$path" "$algo") || h=""
  printf '%s\t%s\n' "$path" "$h" >> "$results_file"
}

# New: batch worker — hashes multiple files sequentially and writes all results.
# Usage: _do_hash_batch <algo> <results_file> <file1> <file2> ...
_do_hash_batch() {
  # Release semaphore token on exit when parallel dirs are active.
  # The trap fires on success, error, or crash — token is always returned.
  [ -n "${SEM_FD:-}" ] && trap '_sem_release' EXIT
  local algo="$1" results_file="$2"
  shift 2
  for path in "$@"; do
    local h
    h=$(file_hash "$path" "$algo") || h=""
    printf '%s\t%s\n' "$path" "$h" >> "$results_file"
  done
}