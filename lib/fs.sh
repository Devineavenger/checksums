#!/usr/bin/env bash
# fs.sh
# Filesystem helpers: exclusions, discovery, cleanup, and simple counts.
# 2.3 adds INCLUDE_PATTERNS and EXCLUDE_PATTERNS support (shell glob patterns).

_safe_name(){ local n="$1"; [ -n "$n" ] || printf '%s' '__DO_NOT_MATCH__'; }

build_exclusions() {
  MD5_EXCL=$(_safe_name "$MD5_FILENAME")
  META_EXCL=$(_safe_name "$META_FILENAME")
  LOG_EXCL=$(_safe_name "$LOG_FILENAME")
  LOCK_EXCL="${META_EXCL}${LOCK_SUFFIX}"
}

# Arrays of include/exclude patterns (glob or regex-like via [[ ]]); default empty.
# These can be set via .checksums.conf or exported before running.
: "${INCLUDE_PATTERNS[@]:=}"
: "${EXCLUDE_PATTERNS[@]:=}"

find_file_expr() {
  local d="$1"
  # Base find with built-in exclusions and generated filenames
  find "$d" -maxdepth 1 -type f \
    ! -name '.DS_Store' ! -name '._*' \
    ! -name "$MD5_EXCL" ! -name "$META_EXCL" ! -name "$LOG_EXCL" ! -name "$LOCK_EXCL" \
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

      [ "$skip" -eq 0 ] && printf '%s\0' "$f"
    done
}

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

count_files(){ find_file_expr "$1" | tr -cd '\0' | wc -c; }
