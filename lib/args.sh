#!/usr/bin/env bash
# shellcheck disable=SC2034
# args.sh
#
# Argument parsing and normalization, preserving original semantics where possible.
# v2.1: structured logs and rotation
# v2.2: -V verify-only
# v2.3: assume-yes/no and config patterns
# v2.3.1: --config FILE option and default <BASE_NAME>.conf

parse_args() {
  LOG_BASE=""
  LOG_FORMAT="${LOG_FORMAT:-text}"  # Default log format; may be overridden by config or CLI
  VERIFY_ONLY=0                     # Verification-only (no writes)
  ASSUME_NO=0                       # assume-no for all prompts
  CONFIG_FILE=""                    # explicit config file path (--config FILE)

  # Support GNU long options via -:
  # Note: options that take an argument must be followed by ':' in the optstring.
  while getopts "f:a:m:l:ndvrFC:p:o:yVh-:" opt 2>/dev/null; do
    case $opt in
      f) BASE_NAME=$OPTARG ;;                # base name for .md5/.meta
      a) PER_FILE_ALGO=$OPTARG ;;            # md5 or sha256
      m) META_SIG_ALGO=$OPTARG ;;            # sha256, md5, or none
      l) LOG_BASE=$OPTARG ;;                 # base name for per-dir logs
      n) DRY_RUN=1 ;;                        # dry run (no writes)
      d) DEBUG=$((DEBUG+1)) ;;               # debug (repeatable)
      v) VERBOSE=$((VERBOSE+1)) ;;           # verbose
      r) FORCE_REBUILD=1 ;;                  # force rebuild ignoring manifests
      F) FIRST_RUN=1 ;;                      # first-run verification
      C) FIRST_RUN_CHOICE=$OPTARG ;;         # skip|overwrite|prompt
      p) PARALLEL_JOBS=$OPTARG ;;            # parallel hashing jobs
      o) LOG_FORMAT=$OPTARG ;;               # text|json|csv
      y) YES=1 ;;                            # assume-yes (non-interactive)
      V) VERIFY_ONLY=1 ;;                    # verification-only audit mode, no writes
      h) usage; exit 0 ;;                    # help
      -)
        # Handle GNU-style long options via getopts hack (-:)
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
            # --config FILE: grab the next positional argument as the file path
            # Using ${!OPTIND} to reference the argument at index OPTIND.
            CONFIG_FILE="${!OPTIND}"
            # Advance OPTIND past the consumed argument
            OPTIND=$((OPTIND + 1))
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
  shift $((OPTIND -1))

  TARGET_DIR="$1"
  [ -n "$TARGET_DIR" ] || { usage; exit 1; }
  [ -d "$TARGET_DIR" ] || fatal "Directory '$TARGET_DIR' not found."

  # Normalize and validate options

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

  # first-run choice must be one of skip|overwrite|prompt
  case "$FIRST_RUN_CHOICE" in
    skip|overwrite|prompt) ;;
    *) fatal "Invalid -C choice: $FIRST_RUN_CHOICE" ;;
  esac

  # parallel jobs must be a positive integer
  case "$PARALLEL_JOBS" in
    ''|*[!0-9]*) fatal "Invalid -p value (must be integer)" ;;
    *) [ "$PARALLEL_JOBS" -lt 1 ] && PARALLEL_JOBS=1 ;;
  esac

  # log format must be text|json|csv
  case "$LOG_FORMAT" in
    text|json|csv) ;;
    *) fatal "Invalid -o format: $LOG_FORMAT (use text|json|csv)" ;;
  esac

  # Filenames derived from base names (preserves original behavior)
  BASE_NAME="${BASE_NAME%%.md5}"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_BASE="${LOG_BASE:-$BASE_NAME}"
  LOG_FILENAME="${LOG_BASE}.log"
}
