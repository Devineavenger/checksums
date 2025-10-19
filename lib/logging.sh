#!/usr/bin/env bash
# logging.sh
#
# Provides logging utilities for the checksums tool.
# Supports multiple formats (text, JSON, CSV), error recording,
# per-run and per-directory logs, rotation with pruning, and audit trail headers.
#
# v2.1: Added structured logs (JSON/CSV) and rotation.
# v2.2: Added audit trail run ID headers.
# v2.3: Rotation kept only 2 old logs (instead of 5).
# v2.6: Unified verbosity handling via log_level (0–3).
# v2.7: Rotation hardening (basename-only, prune always, keep 3).
# v2.8: Explicit logging when FIRST_RUN=1 (console+dir logs).
# v2.9: dir_log_append helper for lightweight per-directory notes (append-only).
# v2.11 (custom): Harden rotate_log() prune to only delete regular rotated files.
# v2.12 (custom): Guard FIRST_RUN header to avoid duplicate first-run entries.

CSV_HEADER_PRINTED=0   # Tracks whether CSV header has been printed for CSV console output

# Guard so FIRST_RUN header is emitted to FIRST_RUN_LOG only once per run
FIRST_RUN_LOGGED=0

# --------------------------------------------------------------------
# Logging levels (numeric):
#   0 = ERROR   (always shown to stderr in text mode)
#   1 = INFO    (default level, normal messages)
#   2 = VERBOSE (shown when -v is passed)
#   3 = DEBUG   (shown when -d is passed)
# --------------------------------------------------------------------

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

  if [ -n "${LOG_FILEPATH:-}" ]; then
    printf '%s [%d] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILEPATH"
  fi
}

# Wrappers
log()    { _global_log 1 "$*"; }
vlog()   { _global_log 2 "$*"; }
dbg()    { _global_log 3 "$*"; }
fatal()  { _global_log 0 "$*"; exit 1; }

record_error() {
  errors+=("$*")
  count_errors=$((count_errors+1))
  _global_log 0 "$*"
}

# --------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------

first_run_log() {
  local msg="$*"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -n "${FIRST_RUN_LOG:-}" ] && printf '%s %s\n' "$ts" "$msg" >> "$FIRST_RUN_LOG"
}

# Append-only helper (used for verify-only traces etc.)
dir_log_append() {
  local dir="$1"; shift
  local msg="$*"
  local logfile="$dir/$LOG_FILENAME"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [ ! -f "$logfile" ] || [ ! -s "$logfile" ]; then
    printf '#run\t%s\t%s\n' "${RUN_ID:-unknown}" "$ts" >> "$logfile"
  fi
  printf '%s %s\n' "$ts" "$msg" >> "$logfile"
}

# Full skip helper: rotate, truncate, header, then write context + skip line
dir_log_skip() {
  local dir="$1"
  local sumf="$dir/$MD5_FILENAME"
  local metaf="$dir/$META_FILENAME"
  local logfile="$dir/$LOG_FILENAME"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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
  local logfile="$1"
  local dir base ts
  dir=$(dirname -- "$logfile")
  base=$(basename -- "$logfile")

  if [ -f "$logfile" ] && [ -s "$logfile" ]; then
    ts=$(date +"%Y%m%d-%H%M%S")
    mv -- "$logfile" "$dir/$base.$ts" || return 1
    log "Rotated $base -> $base.$ts"
  fi

  (
    cd -- "$dir" || exit 0
    # Hardened prune: only consider regular files matching "$base.*"; keep newest two; delete older.
    if find . -maxdepth 1 -type f -name "$base.*" -printf "%T@ %p\n" >/dev/null 2>&1; then
      find . -maxdepth 1 -type f -name "$base.*" -printf "%T@ %p\n" 2>/dev/null \
        | LC_ALL=C sort -r -n \
        | awk 'NR>=3 {print $2}' \
        | xargs -r -- rm -f --
    else
      # Portable fallback without -printf
      # List matching files sorted by time; remove beyond top 2. Guard with -f.
      ls -1t -- "$base".* 2>/dev/null \
        | awk 'NR>=3' \
        | while IFS= read -r f; do
            [ -f "$f" ] && rm -f -- "$f"
          done
    fi
  )
}

log_run_header() {
  local logfile="$1"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '#run\t%s\t%s\n' "${RUN_ID:-unknown}" "$ts" >> "$logfile"

  # Emit FIRST_RUN header and record into FIRST_RUN_LOG only once per run.
  if [ "${FIRST_RUN:-0}" -eq 1 ] && [ "${FIRST_RUN_LOGGED:-0}" -eq 0 ]; then
    printf '#first_run\t%s\n' "$ts" >> "$logfile"
    _global_log 1 "FIRST_RUN=1: initializing fresh manifests"
    first_run_log "FIRST_RUN=1 at $ts"
    FIRST_RUN_LOGGED=1
  fi
}
