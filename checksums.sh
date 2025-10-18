#!/usr/bin/env bash
# checksums.sh - v2.2.0
# Modular checksum manager with parallel + inode incremental hashing
# Adds: summary report, structured logs, log rotation (2.1)
# Adds: verification-only mode (-V) and audit trail with run ID (2.2)

set -o pipefail
shopt -s nullglob

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER="$(cat "$BASE_DIR/VERSION" 2>/dev/null || echo "2.2.0")"
ME="$(basename "$0")"

# === Defaults (can be overridden by CLI options) ===
BASE_NAME="#####checksums#####"   # Base name for generated files (.md5, .meta, .log)
PER_FILE_ALGO="md5"               # Algorithm for per-file checksums: "md5" (default) or "sha256"
META_SIG_ALGO="sha256"            # Algorithm for meta signature: "sha256" (default), "md5", or "none"
LOG_BASE=""                       # Base name for run logs; defaults to BASE_NAME if not set
DRY_RUN=0                         # If 1, simulate actions without writing files (-n)
DEBUG=0                           # Debug verbosity level (-d, repeatable)
VERBOSE=0                         # Verbose logging (-v)
YES=0                             # Auto-confirm prompts (-y)
FORCE_REBUILD=0                   # Force rebuild of checksums, ignoring manifests (-r)
FIRST_RUN=0                       # First-run verification mode (-F)
FIRST_RUN_CHOICE="prompt"         # Action on mismatch in first-run: "skip", "overwrite", or "prompt" (-C)
PARALLEL_JOBS=1                   # Number of parallel hashing jobs (-p N)
LOG_FORMAT="text"                 # Log output format: "text" (default), "json", or "csv" (-o)
VERIFY_ONLY=0                     # Verification-only audit mode (-V); no writes, just checks

# === Filenames (set later based on BASE_NAME/LOG_BASE) ===
MD5_FILENAME=""                   # Will become "<BASE_NAME>.md5"
META_FILENAME=""                  # Will become "<BASE_NAME>.meta"
LOG_FILENAME=""                   # Will become "<LOG_BASE>.log"
LOCK_SUFFIX=".lock"               # Suffix for transient lock files

# === Exclusions (patterns to skip when scanning a directory) ===
MD5_EXCL="" META_EXCL="" LOG_EXCL="" LOCK_EXCL=""

# === Tool detection flags (set in detect_tools) ===
TOOL_md5_cmd=""                   # Command for md5 (md5sum or md5 -r)
TOOL_sha256=""                    # Command for sha256sum
TOOL_shasum=""                    # Command for shasum -a 256
TOOL_stat_gnu=0                   # 1 if GNU stat is available, else 0
TOOL_flock=0                      # 1 if flock is available, else 0

# === Logging state ===
RUN_LOG=""                        # Path to run-level log
LOG_FILEPATH=""                   # Current log file being written
FIRST_RUN_LOG=""                  # Path to first-run verification log

errors=()                         # Array of error messages collected during run
log_level=1                       # Default log verbosity level

# === Summary counters (for central report) ===
count_verified=0                  # Directories verified OK
count_skipped=0                   # Directories skipped (up-to-date)
count_overwritten=0               # Directories overwritten/rebuilt
count_errors=0                    # Errors encountered

# run ID for audit trail
RUN_ID=$(uuidgen 2>/dev/null || date +%s$$)

# Source libraries
for lib in "$BASE_DIR/lib/"*.sh; do
  . "$lib"
done

run_checksums() {
  build_exclusions

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
  log "Run ID: $RUN_ID"
  log "Base: $BASE_NAME  per-file: $PER_FILE_ALGO  meta-sig: $META_SIG_ALGO  dry-run: $DRY_RUN  first-run: $FIRST_RUN choice: $FIRST_RUN_CHOICE  parallel: $PARALLEL_JOBS  format: $LOG_FORMAT  verify-only: $VERIFY_ONLY"

  if [ "$YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
    printf 'About to process directories under %s. Continue? [y/N]: ' "$TARGET_DIR"
    if ! IFS= read -r ans; then exit 1; fi
    case "$ans" in [Yy]*) ;; *) log "Aborted by user"; exit 0 ;; esac
  fi

  if [ "$FIRST_RUN" -eq 1 ]; then
    first_run_verify "$TARGET_DIR"
  fi

  process_directories "$TARGET_DIR"
  cleanup_leftover_locks "$TARGET_DIR"

  # summary
  log "Summary:"
  log "  Verified:    $count_verified"
  log "  Skipped:     $count_skipped"
  log "  Overwritten: $count_overwritten"
  log "  Errors:      $count_errors"

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
