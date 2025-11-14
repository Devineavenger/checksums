#!/usr/bin/env bash
# fs.sh
#
# Filesystem helpers: exclusions, discovery, cleanup, and simple counts.
#
# Responsibilities:
#  - build_exclusions: create safe basename-only exclusion values
#  - find_file_expr: enumerate candidate files for checksumming with built-in
#    and configurable exclusions; emits NUL-delimited results for safe parsing
#  - cleanup_leftover_locks: remove stale lock files left by earlier runs
#  - count_files: quick count of candidate files in a directory
#
# Implementation notes:
#  - All comparisons are done on basenames where possible to avoid find(1) warnings
#  - We intentionally emit NUL-delimited paths so filenames with newlines are handled
#  - INCLUDE_PATTERNS and EXCLUDE_PATTERNS accept shell globs and are applied
#    using [[ .. == pattern ]] so they support basic globbing semantics

_safe_name() {
  # Return a safe non-matching name if input empty to prevent accidental
  # -name "" constructs in find which can produce warnings or unintended matches.
  local n="$1"
  [ -n "$n" ] && printf '%s' "$n" || printf '%s' '__DO_NOT_MATCH__'
}

build_exclusions() {
  # Strip directory components so only basenames are compared in find expressions.
  # This mirrors original behavior which avoided full-path matches for rotated logs.
  MD5_EXCL=$(_safe_name "$(basename "$MD5_FILENAME")")
  META_EXCL=$(_safe_name "$(basename "$META_FILENAME")")
  LOG_EXCL=$(_safe_name "$(basename "$LOG_FILENAME")")
  RUN_EXCL="$(basename "${LOG_BASE:-$BASE_NAME}.run.log")"
  FIRST_RUN_EXCL="$(basename "${LOG_BASE:-$BASE_NAME}.first-run.log")"
  ALT_LOG_EXCL="$(basename "${LOG_BASE:-$BASE_NAME}.log")"
  LOCK_EXCL="${META_EXCL}${LOCK_SUFFIX}"
  # Note: we intentionally don't export these; modules run in same shell so globals suffice.

  # after computing MD5_EXCL, META_EXCL, LOG_EXCL, RUN_BASENAME, FIRST_RUN_BASENAME, ALT_LOG_EXCL, LOCK_EXCL
  # Add all tool-generated basenames to EXCLUDE_PATTERNS so find_file_expr's basename filtering excludes them.
  EXCLUDE_PATTERNS+=("$MD5_EXCL" "$META_EXCL" "$LOG_EXCL" "$RUN_EXCL" "$FIRST_RUN_EXCL" "$ALT_LOG_EXCL" "$LOCK_EXCL")
}

# Default pattern arrays exist in args.sh but we also declare here for safety.
declare -a INCLUDE_PATTERNS=()
declare -a EXCLUDE_PATTERNS=()

find_file_expr() {
  # Emit NUL-delimited list of regular files in the provided directory that are
  # candidates for inclusion in the per-directory checksum manifest.
  # Exclusions applied:
  #  - common OS metadata files (.DS_Store, Apple resource forks)
  #  - tool-generated artifacts like .md5/.meta/.log and rotated logs
  #  - user-supplied EXCLUDE_PATTERNS (applied to the basename)
  #  - if INCLUDE_PATTERNS is non-empty, only matching basenames are allowed
  local d="$1"
  find "$d" -maxdepth 1 -type f \
    ! -name '.DS_Store' ! -name '._*' \
    ! -name "$MD5_EXCL" \
    ! -name "$META_EXCL" \
    ! -name "$LOG_EXCL" \
    ! -name "$ALT_LOG_EXCL" \
    ! -name "$LOCK_EXCL" \
	! -name "$RUN_EXCL" \
    ! -name "$FIRST_RUN_EXCL" \
    ! -name "${ALT_LOG_EXCL}.*" \
    -print0 | while IFS= read -r -d '' f; do
      local fname; fname=$(basename "$f")
      local skip=0

      # Apply exclude patterns first; these are shell globs evaluated with [[ .. == pattern ]]
      if [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
        for pat in "${EXCLUDE_PATTERNS[@]}"; do
          # shellcheck disable=SC2053
          [[ "$fname" == $pat ]] && skip=1 && break
        done
      fi

      # If include patterns are defined, require a match (after exclusions)
      if [ "$skip" -eq 0 ] && [ "${#INCLUDE_PATTERNS[@]}" -gt 0 ]; then
        local match=0
        for pat in "${INCLUDE_PATTERNS[@]}"; do
          # shellcheck disable=SC2053
          [[ "$fname" == $pat ]] && match=1 && break
        done
        [ "$match" -eq 0 ] && skip=1
      fi

      # Emit file path only if it survives all filters
      [ "$skip" -eq 0 ] && printf '%s\0' "$f"
    done
}

cleanup_leftover_locks() {
  # Removes stale .meta.lock or similarly suffixed lock files that are either
  # empty or older than one day (mtime +0). This is a best-effort cleanup:
  # don't fail the run if removal fails.
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

count_files() {
  # Count number of candidate files returned by find_file_expr.
  # We count NUL separators because find_file_expr emits NUL-delimited entries.
  find_file_expr "$1" | tr -cd '\0' | wc -c
}
