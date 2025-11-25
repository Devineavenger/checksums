#!/usr/bin/env bash
# shellcheck disable=SC2034
# args.sh
#
# Purpose:
#   Parse CLI options and normalize global runtime settings for the checksums tool.
#   This module preserves the original semantics while adding:
#     - --skip-empty (affirmative; default already enabled via SKIP_EMPTY=1 in init.sh)
#     - --allow-root-sidefiles (affirmative; flips default NO_ROOT_SIDEFILES=1 to 0)
#     - --config FILE (explicit config file path)
#   It also guards against missing positional DIRECTORY under `set -u`.
#
# Design notes:
#   - We use getopts with the -: hack to support GNU-style long options.
#   - All global variables are defined in init.sh; args.sh only overrides based on CLI.
#   - After parsing, filenames derived from BASE_NAME and LOG_BASE are normalized.
#   - We validate supported values and provide helpful errors via usage() and fatal().
#
# Expected globals (from init.sh):
#   BASE_NAME, PER_FILE_ALGO, META_SIG_ALGO, LOG_BASE, DRY_RUN, DEBUG, VERBOSE, YES,
#   ASSUME_NO, FORCE_REBUILD, FIRST_RUN, FIRST_RUN_CHOICE, PARALLEL_JOBS, LOG_FORMAT,
#   VERIFY_ONLY, CONFIG_FILE, SKIP_EMPTY, NO_ROOT_SIDEFILES,
#   MD5_FILENAME, META_FILENAME, LOG_FILENAME
#
# Provided functions (sourced elsewhere):
#   usage()   - prints help
#   fatal(msg) - prints error and exits
#
# Example:
#   parse_args -a sha256 -o json --assume-yes --allow-root-sidefiles /path/to/project
#   TARGET_DIR will be set and globals updated to match CLI options.

parse_args() {
  # Reset/initialize a few options to ensure CLI overrides are applied cleanly.
  LOG_BASE=""
  LOG_FORMAT="${LOG_FORMAT:-text}"   # text (default), json, csv
  VERIFY_ONLY=0
  ASSUME_NO=0
  CONFIG_FILE=""
  VERIFY_MD5_DETAILS="${VERIFY_MD5_DETAILS:-1}"   # Default will come from init.sh; allow CLI to override. Initialize for safety.

  # getopts optstring:
  #   options with args must be suffixed by ':'
  #   The trailing '-:' enables long options handling via OPTARG parsing.
  while getopts "f:a:m:l:ndvrRFC:p:o:yVhzb:-:" opt 2>/dev/null; do
    case "$opt" in
      # Short options (same as legacy tool)
      f) BASE_NAME=$OPTARG ;;            # base name for .md5/.meta/.log
      a) PER_FILE_ALGO=$OPTARG ;;        # md5 | sha256
      m) META_SIG_ALGO=$OPTARG ;;        # sha256 | md5 | none
      l) LOG_BASE=$OPTARG ;;             # base name for per-dir logs (default: BASE_NAME)
      n) DRY_RUN=1 ;;                    # dry run (no writes)
      d) DEBUG=$((DEBUG+1)) ;;           # debug (repeatable)
      v) VERBOSE=$((VERBOSE+1)) ;;       # verbose
      r) FORCE_REBUILD=1 ;;              # force rebuild ignoring manifests
      R) NO_REUSE=1 ;;                   # short flag: disable reuse heuristics
      F) FIRST_RUN=1 ;;                  # first-run verification/bootstrap mode
      C) FIRST_RUN_CHOICE=$OPTARG ;;     # skip | overwrite | prompt
      z) VERIFY_MD5_DETAILS=0 ;;         # short: -z => disable md5-details (no-md5-details)
      p) PARALLEL_JOBS=$OPTARG ;;        # number of parallel hashing jobs
      b) BATCH_RULES=$OPTARG ;;          # short: -b RULES => adaptive batching rules
      o) LOG_FORMAT=$OPTARG ;;           # text | json | csv
      y) YES=1 ;;                        # assume-yes (non-interactive)
      V) VERIFY_ONLY=1 ;;                # verify-only audit mode (no writes)
      h) usage; exit 0 ;;                # help

      # Long options via getopts -: hack. OPTARG holds the long option name.
      -)
        case "$OPTARG" in
          version)
            printf '%s version %s\n' "$ME" "$VER"
            exit 0
            ;;
          assume-yes)
            YES=1
            ;;
          assume-no)
            ASSUME_NO=1
            ;;
          config)
            # --config FILE (consume next positional as value)
            CONFIG_FILE="${!OPTIND}"
            OPTIND=$((OPTIND + 1))
            ;;
          skip-empty)
            # Affirmative: ensure SKIP_EMPTY enabled (default already 1 in init.sh)
            SKIP_EMPTY=1
            ;;
          no-skip-empty)
            # Disable skipping empty/container-only directories
            SKIP_EMPTY=0
            ;;
          md5-details)
            # Enable optional detailed MD5 verification on .md5-only dirs during planning
            VERIFY_MD5_DETAILS=1
            ;;
          no-md5-details)
            # Disable md5-details in planning
            VERIFY_MD5_DETAILS=0
            ;;
          batch)
            # --batch RULES (consume next positional as value)
            BATCH_RULES="${!OPTIND}"
            OPTIND=$((OPTIND + 1))
            ;;
          allow-root-sidefiles)
            # Affirmative: allow sidecar files (.md5/.meta/.log) in root (default is protected)
            NO_ROOT_SIDEFILES=0
            ;;
          no-reuse)
            NO_REUSE=1
            ;;
          *)
            usage
            exit 1
            ;;
        esac
        ;;
      *)
        usage
        exit 1
        ;;
    esac
  done

  # Move past parsed options to remaining positionals
  shift $((OPTIND - 1))

  # === Sanity check for BATCH_RULES format ===
  # Valid examples: "0-2M:20,2M-50M:10,>50M:1"
  # Pattern: comma‑separated list of ranges "LOW-HIGH:COUNT" or ">HIGH:COUNT"
  # Units: optional K/M/G suffix
  if ! [[ "$BATCH_RULES" =~ ^([0-9]+[KMG]?-[0-9]+[KMG]?:[0-9]+,)*([0-9]+[KMG]?-[0-9]+[KMG]?:[0-9]+|>[0-9]+[KMG]?:[0-9]+)$ ]]; then
    record_error "Invalid --batch/-b rules format: '$BATCH_RULES'. Falling back to default."
    BATCH_RULES="0-2M:20,2M-50M:10,>50M:1"
  fi

  # Guard against missing DIRECTORY under set -u (nounset)
  if [ $# -lt 1 ]; then
    usage
    exit 1
  fi

  TARGET_DIR=$1
  [ -d "$TARGET_DIR" ] || fatal "Directory '$TARGET_DIR' not found."

  # === Normalize and validate options ===

  # per-file algo must be md5 or sha256
  case "$PER_FILE_ALGO" in
    md5|sha256) ;;
    *) fatal "Unsupported per-file algo: $PER_FILE_ALGO" ;;
  esac

  # meta signature algo must be sha256, md5, or none
  case "$META_SIG_ALGO" in
    sha256|md5|none) ;;
    *) fatal "Unsupported meta sig algo: $META_SIG_ALGO" ;;
  esac

  # first-run choice must be one of skip | overwrite | prompt
  case "$FIRST_RUN_CHOICE" in
    skip|overwrite|prompt) ;;
    *) fatal "Invalid -C choice: $FIRST_RUN_CHOICE (use skip|overwrite|prompt)" ;;
  esac

  # parallel jobs must be a positive integer
  case "$PARALLEL_JOBS" in
    ''|*[!0-9]*) fatal "Invalid -p value (must be integer)" ;;
    *) [ "$PARALLEL_JOBS" -lt 1 ] && PARALLEL_JOBS=1 ;;
  esac

  # log format must be text | json | csv
  case "$LOG_FORMAT" in
    text|json|csv) ;;
    *) fatal "Invalid -o format: $LOG_FORMAT (use text|json|csv)" ;;
  esac

  # === Filenames derived from base names ===
  # Preserve original behavior: strip trailing .md5, derive consistent sidecar names.
  BASE_NAME="${BASE_NAME%%.md5}"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_BASE="${LOG_BASE:-$BASE_NAME}"
  LOG_FILENAME="${LOG_BASE}.log"
}
