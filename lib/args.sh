# args.sh

parse_args() {
  # Reset defaults that depend on args
  LOG_BASE=""

  # Parse
  while getopts "f:a:m:l:ndvrFC:p:yVh" opt 2>/dev/null; do
    case $opt in
      f) BASE_NAME=$OPTARG ;;
      a) PER_FILE_ALGO=$OPTARG ;;
      m) META_SIG_ALGO=$OPTARG ;;
      l) LOG_BASE=$OPTARG ;;
      n) DRY_RUN=1 ;;
      d) ((DEBUG++)) ;;
      v) ((VERBOSE++)) ;;
      r) FORCE_REBUILD=1 ;;
      F) FIRST_RUN=1 ;;
      C) FIRST_RUN_CHOICE=$OPTARG ;;
      p) PARALLEL_JOBS=$OPTARG ;;
      y) YES=1 ;;
      V) printf '%s version %s\n' "$ME" "$VER"; exit 0 ;;
      h) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done
  shift $((OPTIND -1))

  TARGET_DIR="$1"
  [ -n "$TARGET_DIR" ] || { usage; exit 1; }
  [ -d "$TARGET_DIR" ] || fatal "Directory '$TARGET_DIR' not found."

  # Normalize and validate options
  case "$PER_FILE_ALGO" in md5|sha256) ;; *) fatal "Unsupported per-file algo: $PER_FILE_ALGO" ;; esac
  case "$META_SIG_ALGO" in sha256|md5|none) ;; *) fatal "Unsupported meta sig algo: $META_SIG_ALGO" ;; esac
  case "$FIRST_RUN_CHOICE" in skip|overwrite|prompt) ;; *) fatal "Invalid -C choice: $FIRST_RUN_CHOICE" ;; esac
  case "$PARALLEL_JOBS" in ''|*[!0-9]*) fatal "Invalid -p value (must be integer)" ;; esac
  [ "$PARALLEL_JOBS" -lt 1 ] && PARALLEL_JOBS=1

  BASE_NAME="${BASE_NAME%%.md5}"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_BASE="${LOG_BASE:-$BASE_NAME}"
  LOG_FILENAME="${LOG_BASE}.log"
}
