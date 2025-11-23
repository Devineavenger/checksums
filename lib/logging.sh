#!/usr/bin/env bash
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
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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
          printf '%s ERROR: %s\n' "$ts" "$msg" >&2
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
  local msg="$*"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -n "${FIRST_RUN_LOG:-}" ] && printf '%s %s\n' "$ts" "$msg" >> "$FIRST_RUN_LOG"
}

dir_log_append() {
  # Lightweight append-only helper for directory-level notes. Ensures a run header
  # exists in the file and then appends the message.
  local dir="$1"; shift
  local msg="$*"
  local logfile="$dir/$LOG_FILENAME"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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
  # When a directory is determined to be up-to-date, rotate/truncate its log
  # and write a short skip notice so operators can see which directories were skipped.
  # Honor SKIP_EMPTY and NO_ROOT_SIDEFILES to avoid creating logs for those cases.
  local dir="$1"
  local sumf="$dir/$MD5_FILENAME"
  local metaf="$dir/$META_FILENAME"
  local logfile="$dir/$LOG_FILENAME"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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
  # - On GNU systems: use stat --format '%Y %n' for mtime + path.
  # - On BSD/macOS: use stat -f '%m %N'.
  # Avoid 'ls' to safely handle special characters in filenames (ShellCheck SC2012).
  if find "$dir" -maxdepth 1 -type f -name "$base_noext.*.log" -print0 | grep -q .; then
    if stat --version >/dev/null 2>&1; then
      # GNU stat path
      find "$dir" -maxdepth 1 -type f -name "$base_noext.*.log" -print0 \
        | xargs -0 stat --format '%Y %n' \
        | sort -nr \
        | awk 'NR>2 {print $2}' \
        | xargs -r rm -f --
    else
      # BSD/macOS stat path
      find "$dir" -maxdepth 1 -type f -name "$base_noext.*.log" -print0 \
        | xargs -0 stat -f '%m %N' \
        | sort -nr \
        | awk 'NR>2 {print $2}' \
        | xargs -r rm -f --
    fi
  fi
}

log_run_header() {
  # Write an audit header into logfile with run id and timestamp.
  local logfile="$1"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
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
      vlog "MD5-DETAIL: verified OK for $d"
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
emit_md5_file_details() {
  local dir="$1" sumf="$2"
  local entry fname expected actual rc=0 missing=0 bad=0 fpath
  [ -f "$sumf" ] || return 2
  # Count how many valid file entries we actually parsed from the sumfile.
  # If the sumfile exists but contains no valid file entries (only blank/comments/
  # otherwise unparsable lines), we treat that as "referenced files missing"
  # (rc=2) so the planner/first-run logic will surface the directory for attention.
  local processed_count=0
  while IFS= read -r entry || [ -n "$entry" ]; do
    # Skip empty or comment lines
    [ -z "$entry" ] && continue
    case "$entry" in \#*) continue ;; esac

    # Parse BSD vs GNU formats
    case "$entry" in
      MD5*=*)  # BSD/macOS format: MD5 (filename) = hash
        fname=$(printf '%s' "$entry" | sed -E 's/^MD5 \((.*)\) = .*/\1/')
        expected=$(printf '%s' "$entry" | awk '{print $NF}')
        ;;
      *)       # GNU format: hash␠␠filename
        expected=${entry%%[[:space:]]*}
        fname=${entry#"$expected"}
        fname=$(printf '%s' "$fname" | sed -E 's/^[[:space:]]+[*[:space:]]*//')
        ;;
    esac

    # normalize filename: remove leading ./ if present
    fname="${fname#./}"

    # skip if still empty (malformed line)
    [ -z "$fname" ] && continue
    processed_count=$((processed_count+1))

    fpath="$dir/$fname"
    if [ ! -e "$fpath" ]; then
      missing=1
      [ -n "${RUN_LOG:-}" ] && printf 'MISSING: %s\n' "$fpath" >>"${RUN_LOG}"
      continue
    fi
    actual=$(file_hash "$fpath" "md5")
    if [ "$actual" != "$expected" ]; then
      bad=1
      [ -n "${RUN_LOG:-}" ] && printf 'MISMATCH: %s\texpected=%s\tactual=%s\n' "$fpath" "$expected" "$actual" >>"${RUN_LOG}"
    fi
  done < "$sumf"
  # If there were no valid file entries in the sumfile but the sumfile is non-empty,
  # treat that as an error (missing referenced files / malformed manifest).
  if [ "$processed_count" -eq 0 ]; then
    # Clarify operator diagnostics: a non-empty sumfile with no parseable entries is malformed.
    # Log it as MALFORMED so run-level logs capture the root cause clearly.
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
  unset processed_count
  return "$rc"
}
