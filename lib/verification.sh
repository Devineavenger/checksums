#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# shellcheck disable=SC2034
# verification.sh
#
# Manifest verification logic: per-file hash comparison against existing manifests,
# and external manifest check mode (sha256sum -c / md5sum -c interop).
#
# Responsibilities:
#  - emit_md5_detail: emit a compact summary (VERIFIED/MISMATCH/MISSING) to console and run log
#  - emit_md5_file_details: dispatcher that selects parallel or sequential verification
#  - _verify_md5_sequential: line-by-line manifest verification (single-threaded)
#  - _verify_md5_parallel: batch-dispatched manifest verification using hash.sh workers
#  - run_check_mode: top-level orchestrator for --check / -c external manifest verification
#  - _check_verify_sequential / _check_verify_parallel: check mode verification paths
#  - _check_detect_algo: infer algorithm from manifest file extension
#  - _check_parse_manifest_line: parse GNU/BSD manifest line into hash + filename
#  - _check_print_summary: emit sha256sum-c compatible summary warnings
#
# These functions are called from process.sh (verify-only path), first_run.sh,
# and checksums.sh (check mode dispatch).
# They depend on logging.sh (log, dbg, vlog) and hash.sh (file_hash, _do_hash_batch,
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

# =========================================================================
# Check mode: verify files against an external manifest (sha256sum -c interop)
# =========================================================================

# _check_detect_algo FILE
#
# Infer the hash algorithm from a manifest file's extension.
# Prints the algorithm name on stdout, or empty string if the extension
# is not a recognized algorithm name.
_check_detect_algo() {
  local file="$1"
  local ext="${file##*.}"
  case "$ext" in
    md5)    printf 'md5' ;;
    sha1)   printf 'sha1' ;;
    sha224) printf 'sha224' ;;
    sha256) printf 'sha256' ;;
    sha384) printf 'sha384' ;;
    sha512) printf 'sha512' ;;
    *)      printf '' ;;
  esac
}

# Globals set by _check_parse_manifest_line for the caller to consume.
# Using globals avoids namerefs (Bash 4.3+) and subshell overhead.
_CHK_EXPECTED=""
_CHK_FNAME=""

# _check_parse_manifest_line LINE
#
# Parse a single manifest line in either GNU or BSD format.
# Sets _CHK_EXPECTED (expected hash) and _CHK_FNAME (relative filename).
# Returns 0 on success, 1 if the line should be skipped (blank, comment,
# or malformed).
#
# Supported formats:
#   GNU:  hash  filename        (two-space separator)
#         hash *filename        (binary-mode marker)
#   BSD:  MD5 (filename) = hash
#         SHA256 (filename) = hash
_check_parse_manifest_line() {
  local line="$1"
  _CHK_EXPECTED=""
  _CHK_FNAME=""

  # Skip blank lines and comments
  [ -z "$line" ] && return 1
  case "$line" in \#*) return 1 ;; esac

  case "$line" in
    # BSD format: ALGO (filename) = hash
    MD5*=*|SHA1*=*|SHA224*=*|SHA256*=*|SHA384*=*|SHA512*=*)
      _CHK_FNAME=$(printf '%s' "$line" | sed -E 's/^[A-Z0-9]+ \((.*)\) = .*/\1/')
      _CHK_EXPECTED=$(printf '%s' "$line" | awk '{print $NF}')
      ;;
    *)
      # GNU format: hash  filename  (or hash *filename for binary)
      _CHK_EXPECTED=${line%%[[:space:]]*}
      _CHK_FNAME=${line#"$_CHK_EXPECTED"}
      _CHK_FNAME=$(printf '%s' "$_CHK_FNAME" | sed -E 's/^[[:space:]]+[*[:space:]]*//')
      ;;
  esac

  # Strip leading ./ from filename (common in checksums-generated manifests)
  _CHK_FNAME="${_CHK_FNAME#./}"
  [ -z "$_CHK_FNAME" ] && return 1
  return 0
}

# _check_print_summary TOTAL OK FAILED READ_ERRORS
#
# Print sha256sum-c compatible summary warnings to stderr.
# Only emits warnings when there are failures or read errors;
# silent on success (matching sha256sum -c behavior).
_check_print_summary() {
  local total="$1" ok="$2" failed="$3" read_errors="$4"

  if [ "$failed" -gt 0 ]; then
    printf '%s: WARNING: %d computed checksum(s) did NOT match\n' \
      "${ME:-checksums}" "$failed" >&2
  fi
  if [ "$read_errors" -gt 0 ]; then
    printf '%s: WARNING: %d listed file(s) could not be read\n' \
      "${ME:-checksums}" "$read_errors" >&2
  fi
}

# _check_verify_sequential ALGO
#
# Sequential verification path for check mode. Reads CHECK_FILE line by line,
# hashes each referenced file, and prints sha256sum-c compatible output.
# Returns 0 if all files verified OK, 1 if any failure.
_check_verify_sequential() {
  local algo="$1"
  local total=0 ok_count=0 fail_count=0 read_error_count=0
  local line

  while IFS= read -r line || [ -n "$line" ]; do
    _check_parse_manifest_line "$line" || continue
    total=$((total + 1))

    # Resolve path: absolute paths used as-is, relative resolved against TARGET_DIR
    local fpath
    case "$_CHK_FNAME" in
      /*) fpath="$_CHK_FNAME" ;;
      *)  fpath="$TARGET_DIR/$_CHK_FNAME" ;;
    esac

    # Check file existence and readability
    if [ ! -e "$fpath" ] || [ ! -r "$fpath" ]; then
      printf '%s: FAILED open or read\n' "$_CHK_FNAME"
      read_error_count=$((read_error_count + 1))
      continue
    fi

    # Compute hash and compare
    local actual
    if ! actual=$(file_hash "$fpath" "$algo"); then
      printf '%s: FAILED open or read\n' "$_CHK_FNAME"
      read_error_count=$((read_error_count + 1))
      continue
    fi

    if [ "$actual" = "$_CHK_EXPECTED" ]; then
      ok_count=$((ok_count + 1))
      [ "${QUIET:-0}" -eq 0 ] && printf '%s: OK\n' "$_CHK_FNAME"
    else
      fail_count=$((fail_count + 1))
      printf '%s: FAILED\n' "$_CHK_FNAME"
    fi
  done < "$CHECK_FILE"

  _check_print_summary "$total" "$ok_count" "$fail_count" "$read_error_count"

  [ "$fail_count" -eq 0 ] && [ "$read_error_count" -eq 0 ] && return 0 || return 1
}

# _check_verify_parallel ALGO
#
# Parallel verification path for check mode. Uses the _do_hash_batch / _par_wait_all
# pattern from hash.sh to hash files in parallel batches, then iterates the original
# manifest order to produce consistent output.
# Returns 0 if all files verified OK, 1 if any failure.
_check_verify_parallel() {
  local algo="$1"
  local total=0 ok_count=0 fail_count=0 read_error_count=0

  # Phase 1: Parse manifest, check existence, collect hashable files
  local -a chk_paths=()      # absolute paths to hash
  local -a chk_names=()      # display names (from manifest)
  local -a chk_expected=()   # expected hashes
  local line

  while IFS= read -r line || [ -n "$line" ]; do
    _check_parse_manifest_line "$line" || continue
    total=$((total + 1))

    local fpath
    case "$_CHK_FNAME" in
      /*) fpath="$_CHK_FNAME" ;;
      *)  fpath="$TARGET_DIR/$_CHK_FNAME" ;;
    esac

    if [ ! -e "$fpath" ] || [ ! -r "$fpath" ]; then
      printf '%s: FAILED open or read\n' "$_CHK_FNAME"
      read_error_count=$((read_error_count + 1))
      continue
    fi

    chk_paths+=("$fpath")
    chk_names+=("$_CHK_FNAME")
    chk_expected+=("$_CHK_EXPECTED")
  done < "$CHECK_FILE"

  # Phase 2: Dispatch parallel hashing batches
  if [ "${#chk_paths[@]}" -gt 0 ]; then
    local verify_dir
    verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/check_verify.XXXXXX")"

    local batch_id=0
    local -a batch_files=()
    local current_batch_size=0
    HASH_PIDS=()
    # shellcheck disable=SC2034
    HASH_PIDS_COUNT=0

    local i
    for i in "${!chk_paths[@]}"; do
      batch_files+=("${chk_paths[$i]}")
      current_batch_size=$((current_batch_size + 1))
      if (( current_batch_size >= PARALLEL_JOBS )); then
        _par_maybe_wait
        _do_hash_batch "$algo" "$verify_dir/batch_${batch_id}.out" "${batch_files[@]}" &
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
      _do_hash_batch "$algo" "$verify_dir/batch_${batch_id}.out" "${batch_files[@]}" &
      HASH_PIDS+=("$!")
      # shellcheck disable=SC2034
      HASH_PIDS_COUNT=${#HASH_PIDS[@]}
    fi

    _par_wait_all

    # Phase 3: Collect results into indexed lookup arrays (path -> hash).
    # Parallel indexed arrays for Bash 3.2 compatibility (no assoc arrays needed).
    local -a result_paths=()
    local -a result_hashes=()
    local rpath rhash
    for worker_out in "$verify_dir"/*.out; do
      [ -f "$worker_out" ] || continue
      while IFS=$'\t' read -r rpath rhash; do
        result_paths+=("$rpath")
        result_hashes+=("$rhash")
      done < "$worker_out"
    done

    rm -rf "$verify_dir" 2>/dev/null || true

    # Phase 4: Iterate in manifest order, look up results, produce output.
    # This ensures output order matches the manifest regardless of worker completion order.
    for i in "${!chk_paths[@]}"; do
      local found_hash=""
      local j
      for j in "${!result_paths[@]}"; do
        if [ "${result_paths[$j]}" = "${chk_paths[$i]}" ]; then
          found_hash="${result_hashes[$j]}"
          break
        fi
      done

      case "${found_hash:-}" in
        "")
          # No result found — file may have vanished between existence check and hashing
          printf '%s: FAILED open or read\n' "${chk_names[$i]}"
          read_error_count=$((read_error_count + 1))
          ;;
        ERROR:*)
          printf '%s: FAILED open or read\n' "${chk_names[$i]}"
          read_error_count=$((read_error_count + 1))
          ;;
        *)
          if [ "$found_hash" = "${chk_expected[$i]}" ]; then
            ok_count=$((ok_count + 1))
            [ "${QUIET:-0}" -eq 0 ] && printf '%s: OK\n' "${chk_names[$i]}"
          else
            fail_count=$((fail_count + 1))
            printf '%s: FAILED\n' "${chk_names[$i]}"
          fi
          ;;
      esac
    done
  fi

  _check_print_summary "$total" "$ok_count" "$fail_count" "$read_error_count"

  [ "$fail_count" -eq 0 ] && [ "$read_error_count" -eq 0 ] && return 0 || return 1
}

# run_check_mode
#
# Top-level orchestrator for --check / -c mode.
# Reads an external manifest file, verifies each listed file against
# its recorded hash, and prints sha256sum-c compatible output to stdout.
# Summary warnings go to stderr.
#
# Globals used:
#   CHECK_FILE    - path to the manifest file (required, set by args.sh)
#   TARGET_DIR    - base directory for resolving relative paths (default CWD)
#   PER_FILE_ALGO - algorithm override; auto-detected from extension if not explicit
#   _ALGO_EXPLICIT - 1 if the user passed -a / --per-file-algo explicitly
#   PARALLEL_JOBS - number of parallel hashing workers (default 1)
#   QUIET         - suppress OK lines when 1
#   VERBOSE/DEBUG - extra detail when set
#
# Exit codes:
#   0 - all files verified successfully
#   1 - at least one failure (mismatch, missing, or unreadable)
run_check_mode() {
  trap '_orch_cleanup' EXIT
  trap '_orch_cleanup; exit 130' INT
  trap '_orch_cleanup; exit 143' TERM

  # Log level setup (consistent with run_status / run_checksums)
  if [ "$DEBUG" -gt 0 ]; then log_level=3
  elif [ "$VERBOSE" -ge 2 ]; then log_level=3
  elif [ "$VERBOSE" -gt 0 ]; then log_level=2
  fi
  if [ "${QUIET:-0}" -eq 1 ]; then
    log_level=0
    PROGRESS=0
  fi

  detect_tools
  detect_stat
  check_bash_version

  # Resolve TARGET_DIR to absolute path
  cd "$TARGET_DIR" || fatal "Cannot cd to $TARGET_DIR"
  TARGET_DIR=$(pwd -P)
  cd - >/dev/null 2>&1 || true

  # Auto-detect algorithm from manifest extension unless user explicitly set -a.
  # _ALGO_EXPLICIT is set to 1 by the -a / --per-file-algo handler in args.sh.
  local algo="${PER_FILE_ALGO:-md5}"
  if [ "${_ALGO_EXPLICIT:-0}" -eq 0 ]; then
    local detected_algo
    detected_algo=$(_check_detect_algo "$CHECK_FILE")
    if [ -n "$detected_algo" ]; then
      algo="$detected_algo"
      dbg "Auto-detected algorithm from manifest extension: $algo"
    fi
  fi
  # Update PER_FILE_ALGO so file_hash / check_required_tools use the right tools
  PER_FILE_ALGO="$algo"

  if ! check_required_tools; then fatal "Missing tools; see output for hints."; fi

  # Resolve CHECK_FILE to absolute path
  case "$CHECK_FILE" in
    /*) ;; # already absolute
    *)  CHECK_FILE="$(cd "$(dirname "$CHECK_FILE")" && pwd -P)/$(basename "$CHECK_FILE")" ;;
  esac

  # No run log for check mode (read-only operation)
  RUN_LOG=""
  LOG_FILEPATH=""

  vlog "Check mode: manifest=$CHECK_FILE algo=$algo base_dir=$TARGET_DIR"

  if [ "${PARALLEL_JOBS:-1}" -gt 1 ]; then
    _check_verify_parallel "$algo"
  else
    _check_verify_sequential "$algo"
  fi
}
