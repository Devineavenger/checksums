#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# verification.sh
#
# Manifest verification logic: per-file hash comparison against existing manifests.
#
# Responsibilities:
#  - emit_md5_detail: emit a compact summary (VERIFIED/MISMATCH/MISSING) to console and run log
#  - emit_md5_file_details: dispatcher that selects parallel or sequential verification
#  - _verify_md5_sequential: line-by-line manifest verification (single-threaded)
#  - _verify_md5_parallel: batch-dispatched manifest verification using hash.sh workers
#
# These functions are called from process.sh (verify-only path) and first_run.sh.
# They depend on logging.sh (log, dbg) and hash.sh (file_hash, _do_hash_batch,
# _par_maybe_wait, _par_wait_all, HASH_PIDS).

# Emit a compact MD5-details summary into the run log and console.
# Usage: emit_md5_detail <dir> <verifier_return_code>
emit_md5_detail() {
  local d="$1" vr="$2"
  case "$vr" in
    0)
      log "MD5-DETAIL: verified OK for $d"
      [ -n "${RUN_LOG:-}" ] && printf 'VERIFIED: %s\n' "$d" >>"${RUN_LOG}"
      ;;
    1)
      log "MD5-DETAIL: mismatches in $d"
      [ -n "${RUN_LOG:-}" ] && printf 'MISMATCH: %s\n' "$d" >>"${RUN_LOG}"
      ;;
    2)
      log "MD5-DETAIL: missing files referenced in $d"
      [ -n "${RUN_LOG:-}" ] && printf 'MISSING: %s\n' "$d" >>"${RUN_LOG}"
      ;;
    *)
      log "MD5-DETAIL: verifier returned $vr for $d"
      ;;
  esac
}

# Emit per-file MD5 details for a directory into RUN_LOG and return verifier rc.
# Usage: emit_md5_file_details <dir> <sumfile>
# Writes lines like:
#   MISSING: /abs/path/to/file
#   MISMATCH: /abs/path\texpected=...\tactual=...
# Returns 0 if all ok, 1 if any mismatch, 2 if any missing (mimics verify_md5_file)
#
# Dispatches to parallel or sequential implementation based on PARALLEL_JOBS.
emit_md5_file_details() {
  if [ "${PARALLEL_JOBS:-1}" -gt 1 ]; then
    _verify_md5_parallel "$@"
  else
    _verify_md5_sequential "$@"
  fi
}

# --- Sequential verification (used when PARALLEL_JOBS <= 1) ---
_verify_md5_sequential() {
  local dir="$1" sumf="$2"
  local entry fname expected actual rc=0 missing=0 bad=0 fpath
  [ -f "$sumf" ] || return 2
  local processed_count=0
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -z "$entry" ] && continue
    case "$entry" in \#*) continue ;; esac

    case "$entry" in
      MD5*=*)
        fname=$(printf '%s' "$entry" | sed -E 's/^MD5 \((.*)\) = .*/\1/')
        expected=$(printf '%s' "$entry" | awk '{print $NF}')
        ;;
      *)
        expected=${entry%%[[:space:]]*}
        fname=${entry#"$expected"}
        fname=$(printf '%s' "$fname" | sed -E 's/^[[:space:]]+[*[:space:]]*//')
        ;;
    esac

    fname="${fname#./}"
    [ -z "$fname" ] && continue
    processed_count=$((processed_count+1))

    fpath="$dir/$fname"
    if [ ! -e "$fpath" ]; then
      missing=1
      [ -n "${RUN_LOG:-}" ] && printf 'MISSING: %s\n' "$fpath" >>"${RUN_LOG}"
      continue
    fi
    if ! actual=$(file_hash "$fpath" "${PER_FILE_ALGO:-md5}"); then
      bad=1
      [ -n "${RUN_LOG:-}" ] && printf 'UNREADABLE: %s\n' "$fpath" >>"${RUN_LOG}"
      continue
    fi
    if [ "$actual" != "$expected" ]; then
      bad=1
      [ -n "${RUN_LOG:-}" ] && printf 'MISMATCH: %s\texpected=%s\tactual=%s\n' "$fpath" "$expected" "$actual" >>"${RUN_LOG}"
    fi
  done < "$sumf"

  if [ "$processed_count" -eq 0 ]; then
    if grep -q '[^[:space:]]' "$sumf" 2>/dev/null; then
      rc=2
      log "MD5-DETAIL: malformed manifest detected in $sumf"
      [ -n "${RUN_LOG:-}" ] && printf 'MALFORMED: %s\n' "$sumf" >>"${RUN_LOG}"
    else
      rc=0
    fi
  elif [ "$missing" -ne 0 ]; then
    rc=2
  elif [ "$bad" -ne 0 ]; then
    rc=1
  else
    rc=0
  fi
  return "$rc"
}

# --- Parallel verification (used when PARALLEL_JOBS > 1) ---
# Uses the same _do_hash_batch / _par_wait_all pattern from hash.sh.
_verify_md5_parallel() {
  local dir="$1" sumf="$2"
  local entry fname expected rc=0 missing=0 bad=0 fpath
  [ -f "$sumf" ] || return 2

  local processed_count=0
  # Indexed arrays for Bash 3 compatibility (no assoc needed)
  local -a to_hash_paths=()
  local -a to_hash_expected=()

  # Phase 1: parse manifest, check existence, collect work
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -z "$entry" ] && continue
    case "$entry" in \#*) continue ;; esac

    case "$entry" in
      MD5*=*)
        fname=$(printf '%s' "$entry" | sed -E 's/^MD5 \((.*)\) = .*/\1/')
        expected=$(printf '%s' "$entry" | awk '{print $NF}')
        ;;
      *)
        expected=${entry%%[[:space:]]*}
        fname=${entry#"$expected"}
        fname=$(printf '%s' "$fname" | sed -E 's/^[[:space:]]+[*[:space:]]*//')
        ;;
    esac

    fname="${fname#./}"
    [ -z "$fname" ] && continue
    processed_count=$((processed_count+1))

    fpath="$dir/$fname"
    if [ ! -e "$fpath" ]; then
      missing=1
      [ -n "${RUN_LOG:-}" ] && printf 'MISSING: %s\n' "$fpath" >>"${RUN_LOG}"
      continue
    fi
    to_hash_paths+=("$fpath")
    to_hash_expected+=("$expected")
  done < "$sumf"

  # Phase 2: dispatch parallel hashing batches
  if [ "${#to_hash_paths[@]}" -gt 0 ]; then
    local verify_dir
    verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/verify.XXXXXX")"
    local batch_id=0 batch_files=() current_batch_size=0
    HASH_PIDS=()
    HASH_PIDS_COUNT=0

    local i
    for i in "${!to_hash_paths[@]}"; do
      batch_files+=("${to_hash_paths[$i]}")
      current_batch_size=$((current_batch_size + 1))
      if (( current_batch_size >= PARALLEL_JOBS )); then
        _par_maybe_wait
        _do_hash_batch "$PER_FILE_ALGO" "$verify_dir/batch_${batch_id}.out" "${batch_files[@]}" &
        HASH_PIDS+=("$!")
        # shellcheck disable=SC2034
        HASH_PIDS_COUNT=${#HASH_PIDS[@]}
        batch_files=()
        current_batch_size=0
        batch_id=$((batch_id + 1))
      fi
    done
    # Flush remainder
    if [ "${#batch_files[@]}" -gt 0 ]; then
      _par_maybe_wait
      _do_hash_batch "$PER_FILE_ALGO" "$verify_dir/batch_${batch_id}.out" "${batch_files[@]}" &
      HASH_PIDS+=("$!")
      # shellcheck disable=SC2034
      HASH_PIDS_COUNT=${#HASH_PIDS[@]}
    fi

    _par_wait_all

    # Phase 3: collect results, compare, log mismatches
    # Build a lookup from path→expected using indexed arrays
    local rpath rhash
    for worker_out in "$verify_dir"/*.out; do
      [ -f "$worker_out" ] || continue
      while IFS=$'\t' read -r rpath rhash; do
        # Detect ERROR sentinel from batch workers (file was unreadable/vanished)
        case "${rhash:-}" in
          ERROR:*)
            bad=1
            [ -n "${RUN_LOG:-}" ] && printf 'UNREADABLE: %s\n' "$rpath" >>"${RUN_LOG}"
            continue
            ;;
        esac
        # Find expected hash for this path
        local j exp=""
        for j in "${!to_hash_paths[@]}"; do
          if [ "${to_hash_paths[$j]}" = "$rpath" ]; then
            exp="${to_hash_expected[$j]}"
            break
          fi
        done
        if [ -n "$exp" ] && [ "$rhash" != "$exp" ]; then
          bad=1
          [ -n "${RUN_LOG:-}" ] && printf 'MISMATCH: %s\texpected=%s\tactual=%s\n' "$rpath" "$exp" "$rhash" >>"${RUN_LOG}"
        fi
      done < "$worker_out"
    done

    rm -rf "$verify_dir" 2>/dev/null || true
  fi

  # Return code logic (same as sequential)
  if [ "$processed_count" -eq 0 ]; then
    if grep -q '[^[:space:]]' "$sumf" 2>/dev/null; then
      rc=2
      log "MD5-DETAIL: malformed manifest detected in $sumf"
      [ -n "${RUN_LOG:-}" ] && printf 'MALFORMED: %s\n' "$sumf" >>"${RUN_LOG}"
    else
      rc=0
    fi
  elif [ "$missing" -ne 0 ]; then
    rc=2
  elif [ "$bad" -ne 0 ]; then
    rc=1
  else
    rc=0
  fi
  return "$rc"
}
