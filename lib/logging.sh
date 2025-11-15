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
vlog()   { _global_log 2 "$*"; }
dbg()    { _global_log 3 "$*"; }
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

  (
    cd -- "$dir" || exit 0
    # Preferred path: use find -printf to produce sortable timestamps when available.
    if find . -maxdepth 1 -type f -name "$base.*.log" -printf "%T@ %p\n" >/dev/null 2>&1; then
      find . -maxdepth 1 -type f -name "$base.*.log" -printf "%T@ %p\n" 2>/dev/null \
        | LC_ALL=C sort -r -n \
        | awk 'NR>=3 {print $2}' \
        | xargs -r -- rm -f --
    else
      # Portable fallback when -printf isn't available: use stat to build sortable pairs.
      find . -maxdepth 1 -type f -name "$base.*.log" 2>/dev/null \
      | while IFS= read -r f; do
          if stat --version >/dev/null 2>&1; then
            printf '%s\t%s\n' "$(stat -c %Y -- "$f" 2>/dev/null)" "$f"
          else
            printf '%s\t%s\n' "$(stat -f %m -- "$f" 2>/dev/null)" "$f"
          fi
      done | LC_ALL=C sort -r -n | awk -F'\t' 'NR>=3 {print $2}' | while IFS= read -r f; do
          [ -f "$f" ] && rm -f -- "$f"
        done
    fi
  )
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
