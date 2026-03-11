#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# logging.sh
#
# Centralized logging utilities used by the tool.
#
# Capabilities:
#  - numeric verbosity levels (0 ERROR, 1 INFO, 2 VERBOSE, 3 DEBUG)
#  - console output formats: text (default), json, csv
#  - per-run and per-dir log file writing; rotation handled in rotate_log
#  - recording and aggregating errors for a final summary
#
# Implementation notes:
#  - _global_log manages both console output (subject to LOG_FORMAT) and
#    optional file output if LOG_FILEPATH is set.
#  - Wrappers log/vlog/dbg/fatal provide convenient level-specific calls.

CSV_HEADER_PRINTED=0   # track CSV header printed to console output
FIRST_RUN_LOGGED=0     # avoid writing FIRST_RUN header more than once per run

_global_log() {
  local level="$1"; shift
  local msg="$*"
  # Use Bash builtin time formatting to avoid spawning `date`
  local ts; ts=$(printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)

  local print_console=0
  [ "${log_level:-1}" -ge 0 ] && [ "$level" -le "${log_level:-1}" ] && print_console=1

  if [ "$print_console" -eq 1 ]; then
    case "${LOG_FORMAT:-text}" in
      json)
        local lvl; case "$level" in
          0) lvl="ERROR" ;; 1) lvl="INFO" ;; 2) lvl="VERBOSE" ;; 3) lvl="DEBUG" ;; *) lvl="INFO" ;;
        esac
        printf '{"ts":"%s","level":"%s","msg":"%s"}\n' "$ts" "$lvl" "$msg"
        ;;
      csv)
        local lvl; case "$level" in
          0) lvl="ERROR" ;; 1) lvl="INFO" ;; 2) lvl="VERBOSE" ;; 3) lvl="DEBUG" ;; *) lvl="INFO" ;;
        esac
        if [ "$CSV_HEADER_PRINTED" -eq 0 ]; then
          echo "timestamp,level,message"
          CSV_HEADER_PRINTED=1
        fi
        printf '%s,%s,"%s"\n' "$ts" "$lvl" "$msg"
        ;;
      *)
        if [ "$level" -eq 0 ]; then
          printf '%s %bERROR:%b %s\n' "$ts" "${_C_RED:-}" "${_C_RST:-}" "$msg" >&2
        elif [ "$level" -ge 2 ]; then
          printf '%b%s %s%b\n' "${_C_DIM:-}" "$ts" "$msg" "${_C_RST:-}"
        else
          printf '%s %s\n' "$ts" "$msg"
        fi
        ;;
    esac
  fi

  # Append to log file if set. We intentionally write a compact, human-readable form.
  if [ -n "${LOG_FILEPATH:-}" ]; then
    printf '%s [%d] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILEPATH"
  fi
}

# Convenience wrappers for common log levels
log()    { _global_log 1 "$*"; }
vlog()   { if [ "${VERBOSE:-0}" -gt 0 ]; then _global_log 2 "$*"; fi; }
dbg()    { if [ "${DEBUG:-0}" -gt 0 ]; then _global_log 3 "$*"; fi; }
fatal()  { _global_log 0 "$*"; exit 1; }

record_error() {
  # Add an error to the in-memory errors array and increment the error counter.
  # Ensure errors array exists (defensive if init.sh wasn't sourced exactly)
  declare -ga errors >/dev/null 2>&1 || true
  errors+=("$*")
  count_errors=$((count_errors+1))
  _global_log 0 "$*"
}

# first_run_log writes detailed first-run traces into the FIRST_RUN_LOG file.
first_run_log() {
  [ "${MINIMAL:-0}" -eq 1 ] && return 0
  local msg="$*"
  local ts; ts=$(printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)
  [ -n "${FIRST_RUN_LOG:-}" ] && printf '%s %s\n' "$ts" "$msg" >> "$FIRST_RUN_LOG"
}

dir_log_append() {
  [ "${MINIMAL:-0}" -eq 1 ] && return 0
  # Lightweight append-only helper for directory-level notes. Ensures a run header
  # exists in the file and then appends the message.
  local dir="$1"; shift
  local msg="$*"
  local logfile
  logfile="$(_sidecar_path "$dir" "$LOG_FILENAME")"
  local ts; ts=$(printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)

  # Honor NO_ROOT_SIDEFILES: do not create logs for the root directory
  if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ -n "${TARGET_DIR:-}" ] && [ "$dir" = "${TARGET_DIR%/}" ]; then
    return 0
  fi

  # Honor SKIP_EMPTY: do not create logs for directories with no files anywhere in subtree.
   if [ "${SKIP_EMPTY:-1}" -eq 1 ] && ! has_files "$dir"; then
    return 0
  fi

  if [ ! -f "$logfile" ] || [ ! -s "$logfile" ]; then
    printf '#run\t%s\t%s\n' "${RUN_ID:-unknown}" "$ts" >> "$logfile"
  fi
  printf '%s %s\n' "$ts" "$msg" >> "$logfile"
}

dir_log_skip() {
  [ "${MINIMAL:-0}" -eq 1 ] && return 0
  # When a directory is determined to be up-to-date, rotate/truncate its log
  # and write a short skip notice so operators can see which directories were skipped.
  # Honor SKIP_EMPTY and NO_ROOT_SIDEFILES to avoid creating logs for those cases.
  local dir="$1"
  local sumf metaf logfile
  sumf="$(_sidecar_path "$dir" "$SUM_FILENAME")"
  metaf="$(_sidecar_path "$dir" "$META_FILENAME")"
  logfile="$(_sidecar_path "$dir" "$LOG_FILENAME")"
  local ts; ts=$(printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)

  # Avoid creating logs in root when NO_ROOT_SIDEFILES=1
  if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ -n "${TARGET_DIR:-}" ] && [ "$dir" = "${TARGET_DIR%/}" ]; then
    return 0
  fi

  # Avoid creating logs for directories with no files anywhere when SKIP_EMPTY=1
  if [ "${SKIP_EMPTY:-1}" -eq 1 ] && ! has_files "$dir"; then
    return 0
  fi

  rotate_log "$logfile"
  : > "$logfile"
  log_run_header "$logfile"

  {
    printf '%s [1] Starting directory: %s\n' "$ts" "$dir"
    printf '%s [1] sumfile: %s  metafile: %s  logfile: %s\n' "$ts" "$sumf" "$metaf" "$logfile"
    printf '%s Skipping %s (manifest indicates up-to-date)\n' "$ts" "$dir"
  } >> "$logfile"
}

rotate_log() {
  [ "${MINIMAL:-0}" -eq 1 ] && return 0
  # Rotate the given logfile by moving it to <logfile>.<timestamp>.log.
  # Do NOT rotate when the logfile exists but appears to be a fresh file
  # (no prior #run header). This avoids creating a rotated file on first write.
  local logfile="$1"
  local dir base ts
  dir=$(dirname -- "$logfile")
  base=$(basename -- "$logfile")
  # Strip a single trailing .log from the base name so rotated files are
  # written as <base>.<ts>.log rather than <base>.log.<ts>.log
  if [[ "$base" == *.log ]]; then
    base_noext="${base%.*}"
  else
    base_noext="$base"
  fi

  if [ -f "$logfile" ] && [ -s "$logfile" ]; then
    # Only rotate if this file contains a prior run header; otherwise treat as new file
    if grep -q '^#run' "$logfile" 2>/dev/null; then
      ts=$(date +"%Y%m%d-%H%M%S")
      mv -- "$logfile" "$dir/$base_noext.$ts.log" || return 1
      log "Rotated $base -> $base_noext.$ts.log"
    else
      # File exists and is non-empty but lacks #run header: do not rotate (first-create scenario)
      log "Not rotating $base (appears to be new; no prior #run header)"
    fi
  fi

  # Simplify rotation cleanup: keep only the 2 most recent rotated logs.
  # Portable approach:
  # - We avoid fragile awk/xargs field-splitting by sorting on the basename
  #   (your timestamps are embedded in the filename as YYYYMMDD-HHMMSS).
  # - This block preserves debug output and explanatory comments.
  # - Works on GNU and BSD/macOS without relying on stat output parsing.

  # Prune rotated logs: keep newest 2, delete the rest
  if find "$dir" -maxdepth 1 -type f -name "$base_noext.*.log" -print0 | grep -q .; then
    dbg "ROTATE: candidates before prune: $(find "$dir" -maxdepth 1 -type f -name "$base_noext.*.log" -printf '%f ' 2>/dev/null)"

    # Build a sorted list of rotated log full paths, newest first.
    # Use find -print0 -> tr to newline to be robust to NUL-delimited output,
    # then sort by the full path reversed (basename timestamp sorts lexicographically).
    # We avoid stat entirely to keep behavior consistent across platforms.
    mapfile -t _all < <(
      find "$dir" -maxdepth 1 -type f -name "$base_noext.*.log" -print0 2>/dev/null \
        | tr '\0' '\n' \
        | LC_ALL=C sort -r
    )

    # If there are more than 2 rotated logs, delete the older ones (everything after index 1)
    if [ "${#_all[@]}" -gt 2 ]; then
      _to_delete=("${_all[@]:2}")
      dbg "ROTATE: deleting: $(printf '%s ' "${_to_delete[@]##*/}")"

      for _p in "${_to_delete[@]}"; do
        # safety: ensure path is non-empty
        if [ -n "$_p" ]; then
          # Use absolute rm to avoid aliases and check result for diagnostics
          /bin/rm -f -- "$_p"
          rc=$?
          if [ $rc -ne 0 ]; then
            dbg "ROTATE: rm failed for '$_p' rc=$rc"
            # extra checks to help diagnose permission/attribute issues
            if [ ! -e "$_p" ]; then
              dbg "ROTATE: file already missing: $_p"
            else
              # stat -c is GNU; fall back to stat -f on BSD/macOS for diagnostics
              if stat --version >/dev/null 2>&1; then
                dbg "ROTATE: file exists but rm failed: $_p (owner=$(stat -c '%U:%G' "$_p" 2>/dev/null) writable=$(test -w "$_p" && echo yes || echo no))"
              else
                dbg "ROTATE: file exists but rm failed: $_p (owner=$(stat -f '%Su:%Sg' "$_p" 2>/dev/null) writable=$(test -w "$_p" && echo yes || echo no))"
              fi
            fi
          fi
        fi
      done
      unset _to_delete
    fi

    dbg "ROTATE: survivors after prune: $(find "$dir" -maxdepth 1 -type f -name "$base_noext.*.log" -printf '%f ' 2>/dev/null)"
    unset _all
  fi
}

log_run_header() {
  [ "${MINIMAL:-0}" -eq 1 ] && return 0
  # Write an audit header into logfile with run id and timestamp.
  local logfile="$1"
  local ts; ts=$(printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)
  printf '#run\t%s\t%s\n' "${RUN_ID:-unknown}" "$ts" >> "$logfile"

  # Emit FIRST_RUN header once per run if requested.
  if [ "${FIRST_RUN:-0}" -eq 1 ] && [ "${FIRST_RUN_LOGGED:-0}" -eq 0 ]; then
    printf '#first_run\t%s\n' "$ts" >> "$logfile"
    _global_log 1 "FIRST_RUN=1: initializing fresh manifests"
    first_run_log "FIRST_RUN=1 at $ts"
    FIRST_RUN_LOGGED=1
  fi
}

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
