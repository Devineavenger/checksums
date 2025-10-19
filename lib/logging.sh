#!/usr/bin/env bash
# logging.sh
#
# Provides logging utilities for the checksums tool.
# Supports multiple formats (text, JSON, CSV), error recording,
# log rotation, and audit trail headers.
#
# v2.1: Added structured logs (JSON/CSV) and rotation.
# v2.2: Added audit trail run ID headers.
# v2.3: Rotation now keeps only 2 old logs (instead of 5).

CSV_HEADER_PRINTED=0   # Tracks whether CSV header has been printed

# _global_log LEVEL MESSAGE...
# Core logging function. Handles formatting based on LOG_FORMAT.
# LEVEL: 0 = ERROR, 1 = INFO, 2 = VERBOSE, 3 = DEBUG
_global_log() {
  local level="$1"; shift; local msg="$*"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")  # UTC timestamp

  case "$LOG_FORMAT" in
    json)
      # JSON structured log line
      local lvl; [ "$level" -eq 0 ] && lvl="ERROR" || lvl="INFO"
      printf '{"ts":"%s","level":"%s","msg":"%s"}\n' "$ts" "$lvl" "$msg"
      ;;
    csv)
      # CSV structured log line
      local lvl; [ "$level" -eq 0 ] && lvl="ERROR" || lvl="INFO"
      if [ "$CSV_HEADER_PRINTED" -eq 0 ]; then
        echo "timestamp,level,message"
        CSV_HEADER_PRINTED=1
      fi
      printf '%s,%s,"%s"\n' "$ts" "$lvl" "$msg"
      ;;
    *)
      # Default plain text logging
      if [ "$level" -eq 0 ]; then
        printf '%s ERROR: %s\n' "$ts" "$msg" >&2
      else
        printf '%s %s\n' "$ts" "$msg"
      fi
      ;;
  esac

  # Always append to current log file if set
  [ -n "$LOG_FILEPATH" ] && printf '%s %s\n' "$ts" "$msg" >> "$LOG_FILEPATH"
}

# Convenience wrappers
log()    { _global_log 1 "$*"; }   # Normal info log
vlog()   { [ "$VERBOSE" -gt 0 ] && _global_log 2 "$*"; }  # Verbose log
dbg()    { [ "$DEBUG" -gt 0 ] && _global_log 3 "$*"; }    # Debug log
fatal()  { _global_log 0 "$*"; exit 1; }                  # Fatal error, exit
record_error() {
  errors+=("$*")
  count_errors=$((count_errors+1))
  _global_log 0 "$*"
}

# first_run_log MESSAGE...
# Writes a message to the first-run verification log (if enabled).
first_run_log() {
  local msg="$*"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -n "$FIRST_RUN_LOG" ] && printf '%s %s\n' "$ts" "$msg" >> "$FIRST_RUN_LOG"
}

# rotate_log FILE
# Rotates an existing log file by renaming it with a timestamp suffix.
# Keeps only the 2 most recent rotated logs (v2.3).
rotate_log() {
  local logfile="$1"
  if [ -f "$logfile" ]; then
    local ts; ts=$(date +"%Y%m%d-%H%M%S")
    mv "$logfile" "${logfile}.${ts}"
    # Keep only last 2 rotated logs
#    ls -1t "${logfile}".* 2>/dev/null | tail -n +3 | xargs -r rm -f --
  find . -maxdepth 1 -name "${logfile}.*" -type f -printf '%T@ %p\n' \
    | sort -nr \
    | tail -n +3 \
    | cut -d' ' -f2- \
    | xargs -r rm -f --
  fi
}

# log_run_header FILE
# Appends a run header line with run ID and timestamp to a log file.
# Provides an audit trail of when and under which run ID the log was created.
log_run_header() {
  local logfile="$1"
  printf '#run\t%s\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$logfile"
}
