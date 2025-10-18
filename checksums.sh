#!/usr/bin/env bash
# checksums.sh - v2.0.0
# Modular checksum manager with parallel + inode incremental hashing

set -o pipefail
shopt -s nullglob

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER="$(cat "$BASE_DIR/VERSION" 2>/dev/null || echo "2.0.0")"
ME="$(basename "$0")"

# Defaults (global)
BASE_NAME="#####checksums#####"
PER_FILE_ALGO="md5"       # md5 or sha256
META_SIG_ALGO="sha256"    # sha256, md5, or none
LOG_BASE=""
DRY_RUN=0
DEBUG=0
VERBOSE=0
YES=0
FORCE_REBUILD=0
FIRST_RUN=0
FIRST_RUN_CHOICE="prompt" # skip | overwrite | prompt
PARALLEL_JOBS=1

# filenames set after args parse
MD5_FILENAME=""
META_FILENAME=""
LOG_FILENAME=""
LOCK_SUFFIX=".lock"

# exclusions
MD5_EXCL="" META_EXCL="" LOG_EXCL="" LOCK_EXCL=""

# tools flags
TOOL_md5_cmd="" TOOL_sha256="" TOOL_shasum="" TOOL_stat_gnu=0 TOOL_flock=0

# logs
RUN_LOG="" LOG_FILEPATH="" FIRST_RUN_LOG=""

errors=()
log_level=1

# Source libraries
for lib in "$BASE_DIR/lib/"*.sh; do
  # shellcheck source=/dev/null
  . "$lib"
done

run_checksums() {
  build_exclusions

  # run-level log (in current working dir)
  RUN_LOG="./${LOG_BASE:-$BASE_NAME}.run.log"
  LOG_FILEPATH="$RUN_LOG"
  : > "$RUN_LOG"

  [ "$DEBUG" -gt 0 ] && log_level=3
  [ "$VERBOSE" -gt 0 ] && [ "$DEBUG" -eq 0 ] && log_level=2

  detect_tools
  if ! check_required_tools; then fatal "Missing tools; see run log for hints."; fi

  cd "$TARGET_DIR" || fatal "Cannot cd to $TARGET_DIR"
  TARGET_DIR=$(pwd -P)
  cd - >/dev/null 2>&1 || true
  [ "$TARGET_DIR" = "/" ] && fatal "Refusing to run on system root"

  log "Starting run on $TARGET_DIR"
  log "Base: $BASE_NAME  per-file: $PER_FILE_ALGO  meta-sig: $META_SIG_ALGO  dry-run: $DRY_RUN  first-run: $FIRST_RUN choice: $FIRST_RUN_CHOICE  parallel: $PARALLEL_JOBS"

  if [ "$YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    printf 'About to process directories under %s. Continue? [y/N]: ' "$TARGET_DIR"
    if ! IFS= read -r ans; then exit 1; fi
    case "$ans" in [Yy]*) ;; *) log "Aborted by user"; exit 0 ;; esac
  fi

  if [ "$FIRST_RUN" -eq 1 ]; then
    first_run_verify "$TARGET_DIR"
  fi

  process_directories "$TARGET_DIR"
  cleanup_leftover_locks "$TARGET_DIR"

  if [ "${#errors[@]}" -gt 0 ]; then
    log "Completed with ${#errors[@]} errors. See run log ${RUN_LOG} and first-run log ${FIRST_RUN_LOG:-none}"
    for e in "${errors[@]}"; do _global_log 0 "ERR: $e"; done
    exit 1
  fi

  log "Completed successfully."
  exit 0
}

main() {
  parse_args "$@"
  run_checksums
}

main "$@"
