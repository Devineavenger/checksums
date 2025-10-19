#!/usr/bin/env bash
# fs.sh
#
# Filesystem helpers: exclusions, discovery, cleanup, and simple counts.
#
# v2.3: Added INCLUDE_PATTERNS and EXCLUDE_PATTERNS support (shell glob patterns).
# v2.6: Hardened exclusions:
#       - Exclude the main .log file
#       - Exclude rotated logs like "<BASE>.log.YYYYMMDD-HHMMSS"
#       - Exclude run logs "*.run.log"
#       - Use basenames only to avoid find(1) warnings

# --------------------------------------------------------------------
# _safe_name STRING
# Returns STRING if non-empty, otherwise a dummy pattern that will
# never match. Prevents accidental empty -name "" in find.
# --------------------------------------------------------------------
_safe_name() {
  local n="$1"
  [ -n "$n" ] && printf '%s' "$n" || printf '%s' '__DO_NOT_MATCH__'
}

# --------------------------------------------------------------------
# build_exclusions
# Sets up exclusion variables for generated files so they are not
# included in checksum manifests.
# Must be called after parse_args has set MD5_FILENAME, META_FILENAME,
# LOG_FILENAME, LOG_BASE, etc.
# --------------------------------------------------------------------
build_exclusions() {
  # Always strip directory components so we only compare basenames
  MD5_EXCL=$(_safe_name "$(basename "$MD5_FILENAME")")
  META_EXCL=$(_safe_name "$(basename "$META_FILENAME")")
  LOG_EXCL=$(_safe_name "$(basename "$LOG_FILENAME")")
  ALT_LOG_EXCL="$(basename "${LOG_BASE:-$BASE_NAME}.log")"
  LOCK_EXCL="${META_EXCL}${LOCK_SUFFIX}"
}

# --------------------------------------------------------------------
# Arrays of include/exclude patterns (glob or regex-like via [[ ]]).
# These can be set via config file or environment before running.
# --------------------------------------------------------------------
declare -a INCLUDE_PATTERNS=()
declare -a EXCLUDE_PATTERNS=()

# --------------------------------------------------------------------
# find_file_expr DIR
# Emits (NUL-delimited) the list of files in DIR that should be
# checksummed, applying built-in exclusions and user patterns.
# --------------------------------------------------------------------
find_file_expr() {
  local d="$1"
  find "$d" -maxdepth 1 -type f \
    ! -name '.DS_Store' ! -name '._*' \
    ! -name "$MD5_EXCL" \
    ! -name "$META_EXCL" \
    ! -name "$LOG_EXCL" \
    ! -name "$ALT_LOG_EXCL" \
    ! -name "$LOCK_EXCL" \
    ! -name '*.run.log' \
    ! -name "${ALT_LOG_EXCL}.*" \
    -print0 | while IFS= read -r -d '' f; do
      local fname; fname=$(basename "$f")
      local skip=0

      # Apply exclude patterns first
      if [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
        for pat in "${EXCLUDE_PATTERNS[@]}"; do
          # shellcheck disable=SC2053
          [[ "$fname" == $pat ]] && skip=1 && break
        done
      fi

      # Apply include patterns only if any are defined
      if [ "$skip" -eq 0 ] && [ "${#INCLUDE_PATTERNS[@]}" -gt 0 ]; then
        local match=0
        for pat in "${INCLUDE_PATTERNS[@]}"; do
          # shellcheck disable=SC2053
          [[ "$fname" == $pat ]] && match=1 && break
        done
        [ "$match" -eq 0 ] && skip=1
      fi

      # Emit file if not skipped
      [ "$skip" -eq 0 ] && printf '%s\0' "$f"
    done
}

# --------------------------------------------------------------------
# cleanup_leftover_locks DIR
# Removes stale .meta.lock files (empty or older than 1 day).
# --------------------------------------------------------------------
cleanup_leftover_locks() {
  local base_dir="$1"
  find "$base_dir" -type f -name "*${LOCK_SUFFIX}" -print0 2>/dev/null \
    | while IFS= read -r -d '' lf; do
        case "$lf" in *".meta.lock"*)
          if [ ! -s "$lf" ] || [ "$(find "$lf" -mtime +0 -print 2>/dev/null)" ]; then
            dbg "Removing leftover lock file $lf"
            rm -f -- "$lf" 2>/dev/null || dbg "Could not remove $lf"
          fi
        esac
      done
}

# --------------------------------------------------------------------
# count_files DIR
# Returns the number of candidate files in DIR.
# --------------------------------------------------------------------
count_files() {
  find_file_expr "$1" | tr -cd '\0' | wc -c
}
