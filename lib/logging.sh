# logging.sh
# Handles logging in text/json/csv formats, error recording, and log rotation.
# Now also supports audit trail headers with run ID.

CSV_HEADER_PRINTED=0

_global_log() {
  local level="$1"; shift; local msg="$*"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  case "$LOG_FORMAT" in
    json)
      local lvl; [ "$level" -eq 0 ] && lvl="ERROR" || lvl="INFO"
      printf '{"ts":"%s","level":"%s","msg":"%s"}\n' "$ts" "$lvl" "$msg"
      ;;
    csv)
      local lvl; [ "$level" -eq 0 ] && lvl="ERROR" || lvl="INFO"
      if [ "$CSV_HEADER_PRINTED" -eq 0 ]; then
        echo "timestamp,level,message"; CSV_HEADER_PRINTED=1
      fi
      printf '%s,%s,"%s"\n' "$ts" "$lvl" "$msg"
      ;;
    *)
      if [ "$level" -eq 0 ]; then printf '%s ERROR: %s\n' "$ts" "$msg" >&2
      else printf '%s %s\n' "$ts" "$msg"; fi
      ;;
  esac

  [ -n "$LOG_FILEPATH" ] && printf '%s %s\n' "$ts" "$msg" >> "$LOG_FILEPATH"
}
log()    { _global_log 1 "$*"; }
vlog()   { [ "$VERBOSE" -gt 0 ] && _global_log 2 "$*"; }
dbg()    { [ "$DEBUG" -gt 0 ] && _global_log 3 "$*"; }
fatal()  { _global_log 0 "$*"; exit 1; }
record_error() { errors+=("$*"); count_errors=$((count_errors+1)); _global_log 0 "$*"; }

first_run_log() {
  local msg="$*"; local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  [ -n "$FIRST_RUN_LOG" ] && printf '%s %s\n' "$ts" "$msg" >> "$FIRST_RUN_LOG"
}

rotate_log() {
  local logfile="$1"
  if [ -f "$logfile" ]; then
    local ts; ts=$(date +"%Y%m%d-%H%M%S")
    mv "$logfile" "${logfile}.${ts}"
    ls -1t "${logfile}".* 2>/dev/null | tail -n +6 | xargs -r rm -f --
  fi
}

log_run_header() {
  local logfile="$1"
  printf '#run\t%s\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$logfile"
}
