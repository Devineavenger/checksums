# Version: 2.5.16
#!/usr/bin/env bash
# shellcheck disable=SC2034
# checksums.sh
#
# Modular checksum manager with parallel + inode incremental hashing
#
# v2.1: summary report, structured logs, log rotation
# v2.2: verification-only mode (-V), audit trail with run ID
# v2.3: config file support, skip/include patterns, non-interactive modes, 2-log rotation
# v2.3.1: --config FILE option and default <BASE_NAME>.conf
# v2.4: cross-platform stat abstraction, Bash 3.2 fallback for associative arrays

set -euo pipefail
shopt -s nullglob

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER="$(cat "$BASE_DIR/VERSION" 2>/dev/null || echo "2.4.0")"
ME="$(basename "$0")"

# === Defaults (can be overridden by config file or CLI) ===
BASE_NAME="#####checksums#####"   # Base name for generated files (.md5, .meta, .log)
PER_FILE_ALGO="md5"               # Algorithm for per-file checksums: "md5" (default) or "sha256"
META_SIG_ALGO="sha256"            # Algorithm for meta signature: "sha256" (default), "md5", or "none"
LOG_BASE=""                       # Base name for run logs; defaults to BASE_NAME if not set
DRY_RUN=0                         # If 1, simulate actions without writing files (-n)
DEBUG=0                           # Debug verbosity level (-d, repeatable)
VERBOSE=0                         # Verbose logging (-v)
YES=0                             # Auto-confirm prompts (-y or --assume-yes)
ASSUME_NO=0                       # Auto-decline prompts (--assume-no)
FORCE_REBUILD=0                   # Force rebuild of checksums, ignoring manifests (-r)
FIRST_RUN=0                       # First-run verification mode (-F)
FIRST_RUN_CHOICE="prompt"         # Action on mismatch in first-run: "skip", "overwrite", or "prompt" (-C)
PARALLEL_JOBS=1                   # Number of parallel hashing jobs (-p N)
LOG_FORMAT="text"                 # Log output format: "text" (default), "json", or "csv" (-o)
VERIFY_ONLY=0                     # Verification-only audit mode (-V); no writes, just checks
CONFIG_FILE=""                    # explicit config file path (--config FILE)

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
TOOL_stat_gnu=0                   # retained for compatibility with older modules (not used in 2.4)
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

# === Run ID for audit trail (2.2+) ===
RUN_ID=$(uuidgen 2>/dev/null || date +%s$$)

# === Source libraries ===
for lib in "$BASE_DIR/lib/"*.sh; do
  # shellcheck source=/dev/null
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
  detect_stat         # v2.4: detect stat style once and cache format strings
  check_bash_version  # v2.4: detect Bash version for assoc array fallback

  if ! check_required_tools; then fatal "Missing tools; see run log for hints."; fi

  cd "$TARGET_DIR" || fatal "Cannot cd to $TARGET_DIR"
  TARGET_DIR=$(pwd -P)
  cd - >/dev/null 2>&1 || true
  [ "$TARGET_DIR" = "/" ] && fatal "Refusing to run on system root"

  # === Config file support (2.3.1 extended) ===
  # Priority:
  #   1. --config FILE if provided
  #   2. Default: <BASE_NAME>.conf in target root (e.g., #####checksums#####.conf)
  if [ -n "$CONFIG_FILE" ]; then
    if [ -f "$CONFIG_FILE" ]; then
      log "Loading config from explicit file $CONFIG_FILE"
      # shellcheck source=/dev/null
      . "$CONFIG_FILE"
    else
      fatal "Config file specified but not found: $CONFIG_FILE"
    fi
  else
    DEFAULT_CONF="$TARGET_DIR/${BASE_NAME}.conf"
    if [ -f "$DEFAULT_CONF" ]; then
      log "Loading config from default $DEFAULT_CONF"
      # shellcheck source=/dev/null
      . "$DEFAULT_CONF"
    fi
  fi

  log "Starting run on $TARGET_DIR"
  log "Run ID: $RUN_ID"
  log "Base: $BASE_NAME  per-file: $PER_FILE_ALGO  meta-sig: $META_SIG_ALGO  dry-run: $DRY_RUN  first-run: $FIRST_RUN choice: $FIRST_RUN_CHOICE  parallel: $PARALLEL_JOBS  format: $LOG_FORMAT  verify-only: $VERIFY_ONLY"

  # === Prompt handling with assume-yes/no (2.3) ===
  if [ "$YES" -eq 0 ] && [ "$ASSUME_NO" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
    printf 'About to process directories under %s. Continue? [y/N]: ' "$TARGET_DIR"
    if ! IFS= read -r ans; then exit 1; fi
    case "$ans" in [Yy]*) ;; *) log "Aborted by user"; exit 0 ;; esac
  elif [ "$ASSUME_NO" -eq 1 ]; then
    log "Aborted by assume-no mode"
    exit 0
  fi

  # === First-run verification step (optional) ===
  if [ "$FIRST_RUN" -eq 1 ]; then
    first_run_verify "$TARGET_DIR"
  fi

  # === Normal processing ===
  process_directories "$TARGET_DIR"
  cleanup_leftover_locks "$TARGET_DIR"

  # === Central summary report (2.1+) ===
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
