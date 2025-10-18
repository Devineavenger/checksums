# logging.sh

_global_log() {
  local level="$1"; shift; local msg="$*"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [ "$level" -le "$log_level" ]; then
    if [ "$level" -eq 0 ]; then printf '%s ERROR: %s\n' "$ts" "$msg" >&2
    else printf '%s %s\n' "$ts" "$msg"
    fi
  fi
  [ -n "$LOG_FILEPATH" ] && printf '%s %s\n' "$ts" "$msg" >> "$LOG_FILEPATH"
}
log()    { _global_log 1 "$*"; }
vlog()   { [ "$VERBOSE" -gt 0 ] && _global_log 2 "$*"; }
dbg()    { [ "$DEBUG" -gt 0 ] && _global_log 3 "$*"; }
fatal()  { _global_log 0 "$*"; exit 1; }
record_error() { errors+=("$*"); _global_log 0 "$*"; }

first_run_log() {
  local msg="$*"; local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -n "$FIRST_RUN_LOG" ] && printf '%s %s\n' "$ts" "$msg" >> "$FIRST_RUN_LOG"
}
