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

# Ensure derived exclusion names are available even if build_exclusions() hasn't been run.
# This makes the helpers safe to call in isolation (interactive tests, unit probes).
# We provide safe defaults here to avoid unbound variables under `set -u`.
MD5_EXCL="${MD5_EXCL:-$(_safe_name "$(basename "${MD5_FILENAME:-#####checksums#####.md5}")")}"
META_EXCL="${META_EXCL:-$(_safe_name "$(basename "${META_FILENAME:-#####checksums#####.meta}")")}"
LOG_EXCL="${LOG_EXCL:-$(_safe_name "$(basename "${LOG_FILENAME:-#####checksums#####.log}")")}"
ALT_LOG_EXCL="${ALT_LOG_EXCL:-$(_safe_name "$(basename "${LOG_BASE:-#####checksums#####}")")}"
RUN_EXCL="${RUN_EXCL:-$(_safe_name "$(basename "${LOG_BASE:-#####checksums#####}.run.log")")}"
FIRST_RUN_EXCL="${FIRST_RUN_EXCL:-$(_safe_name "$(basename "${LOG_BASE:-#####checksums#####}.first-run.log")")}"
LOCK_EXCL="${LOCK_EXCL:-$(_safe_name "${LOCK_SUFFIX:-.lock}")}"

# Default pattern arrays exist in args.sh but we also declare here for safety.
declare -a INCLUDE_PATTERNS=${INCLUDE_PATTERNS:+("${INCLUDE_PATTERNS[@]}")}
declare -a EXCLUDE_PATTERNS=${EXCLUDE_PATTERNS:+("${EXCLUDE_PATTERNS[@]}")}

# normalize_unit: produce numfmt-friendly IEC tokens (plain number, K, M, G, T, P, E),
# or the "Ki/Mi/Gi" form if you prefer explicit binary suffix (both accepted by numfmt).
normalize_unit() {
  local val="$1"
  local num suffix
  num=$(printf '%s' "$val" | sed -E 's/^([0-9]+).*/\1/')
  suffix=$(printf '%s' "$val" | sed -E 's/^[0-9]+//')
  suffix=$(echo "$suffix" | tr '[:upper:]' '[:lower:]')

  case "$suffix" in
    '' )        echo "$num" ;;            # plain number
    b)          echo "${num}" ;;          # bytes as plain number
    k|kb|kib)   echo "${num}K" ;;         # numfmt accepts "K" or "Ki"
    m|mb|mib)   echo "${num}M" ;;
    g|gb|gib)   echo "${num}G" ;;
    t|tb|tib)   echo "${num}T" ;;
    p|pb|pib)   echo "${num}P" ;;
    e|eb|eib)   echo "${num}E" ;;
    *)          echo "$val" ;;            # unknown suffix, leave unchanged
  esac
}

# bytes_from_unit: accept outputs from normalize_unit (plain number or K/M/G/T/P/E)
bytes_from_unit() {
  local val="$1"
  local num suffix
  num="${val%%[A-Za-z]*}"
  suffix="${val#"$num"}"
  case "$suffix" in
    ""|b|B) echo "$num" ;;
    K)      echo $(( num * 1024 )) ;;
    M)      echo $(( num * 1024 * 1024 )) ;;
    G)      echo $(( num * 1024 * 1024 * 1024 )) ;;
    T)      echo $(( num * 1024 * 1024 * 1024 * 1024 )) ;;
    P)      echo $(( num * 1024 * 1024 * 1024 * 1024 * 1024 )) ;;
    E)      echo $(( num * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 )) ;;
    *)      echo "$num" ;;
  esac
}

declare -gA TO_BYTES_CACHE=()

# Convert a human unit token to bytes, with caching to avoid repeated subprocess calls.
_to_bytes() {
  local token="$1"
  # Return cached value if present
  if [ -n "${TO_BYTES_CACHE[$token]:-}" ]; then
    printf '%s' "${TO_BYTES_CACHE[$token]}"
    return
  fi

  local out=""
  if [ "${TOOL_numfmt:-0}" -eq 1 ]; then
    out=$(numfmt --from=iec <<<"$(normalize_unit "$token")" 2>/dev/null || true)
  fi
  if [ -z "$out" ]; then
    out="$(bytes_from_unit "$(normalize_unit "$token")")"
  fi
  out="${out//[[:space:]]/}"
  TO_BYTES_CACHE["$token"]="$out"
  printf '%s' "$out"
}

# Cache-friendly listing helper: centralize find invocation to a single place,
# making it easier to swap for memoization if needed without touching callers.
list_files_cached() {
  local d="$1"
  find "$d" -type f -print0 2>/dev/null
}

# has_files DIR
# Return success (0) if any regular file exists anywhere under DIR that is NOT
# a tool-generated artifact (.md5, .meta, .log, rotated logs). Otherwise return 1.
has_files() {
  local d="$1" f fname
  # Iterate once over a cached listing stream; exit early on first user file match.
  while IFS= read -r -d '' f; do
    fname=$(basename "$f")
    # Skip our tool-generated files: exact base names and rotated variants.
    # Note: use unquoted patterns in case arms so shell globs are interpreted
    # for matching rather than literal strings. ALT_LOG_EXCL is the log base
    # (without the trailing .log) so rotated names are like "<base>.<ts>.log".
    case "$fname" in
      "$MD5_EXCL" | "$META_EXCL" | "$LOG_EXCL" ) continue ;;
      # rotated logs: base.<ts>.log (tolerate legacy variants too)
      ${ALT_LOG_EXCL}.*.log ) continue ;;
      # run-level and first-run logs (explicit names — match literally)
      "$RUN_EXCL" | "$FIRST_RUN_EXCL" ) continue ;;
      # lock suffix
      *"$LOCK_SUFFIX") continue ;;
      # If the basename matches any EXCLUDE_PATTERNS, treat as excluded too
      *)
        # Safely check for EXCLUDE_PATTERNS presence and iterate if non-empty
        if [ "${EXCLUDE_PATTERNS:+1}" = "1" ] && [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
          local pat
          for pat in "${EXCLUDE_PATTERNS[@]}"; do
            # shellcheck disable=SC2053
            [[ "$fname" == $pat ]] && { fname=""; break; }
          done
          [ -z "$fname" ] && continue
        fi
        # Found a non-tool regular file — return success immediately.
        return 0
        ;;
    esac
  done < <(list_files_cached "$d")
  return 1
}

# has_local_files DIR
# Return 0 if there is any regular file directly inside DIR (maxdepth 1)
# excluding known tool-generated files/patterns (same exclusions as has_files).
has_local_files() {
  local d="$1" f fname
  while IFS= read -r -d '' f; do
    fname=$(basename "$f")
    # Mirror the same exclusions as has_files but only consider files directly
    # inside the directory (maxdepth 1). This prevents creating sidecars for
    # parent/container dirs that contain files only in subdirectories.
    case "$fname" in
      "$MD5_EXCL" | "$META_EXCL" | "$LOG_EXCL" ) continue ;;
      ${ALT_LOG_EXCL}.*.log ) continue ;;
      "$RUN_EXCL" | "$FIRST_RUN_EXCL" ) continue ;;
      *"$LOCK_SUFFIX") continue ;;
      *)
        if [ "${EXCLUDE_PATTERNS:+1}" = "1" ] && [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
          local pat skip=0
          for pat in "${EXCLUDE_PATTERNS[@]}"; do
            # shellcheck disable=SC2053
            [[ "$fname" == $pat ]] && skip=1 && break
          done
          [ "$skip" -eq 1 ] && continue
        fi
        return 0
        ;;
    esac
  done < <(find "$d" -maxdepth 1 -type f -print0 2>/dev/null)
  return 1
}

build_exclusions() {
  # Strip directory components so only basenames are compared in find expressions.
  # This mirrors original behavior which avoided full-path matches for rotated logs.
  MD5_EXCL=$(_safe_name "$(basename "$MD5_FILENAME")")
  META_EXCL=$(_safe_name "$(basename "$META_FILENAME")")
  LOG_EXCL=$(_safe_name "$(basename "$LOG_FILENAME")")
  RUN_EXCL="$(basename "${LOG_BASE:-$BASE_NAME}.run.log")"
  FIRST_RUN_EXCL="$(basename "${LOG_BASE:-$BASE_NAME}.first-run.log")"
  # ALT_LOG_EXCL is the log base without the .log suffix so rotated logs can be matched as:
  #   <ALT_LOG_EXCL>.<timestamp>.log
  ALT_LOG_EXCL="$(basename "${LOG_BASE:-$BASE_NAME}")"
  LOCK_EXCL="${META_EXCL}${LOCK_SUFFIX}"
  # Note: we intentionally don't export these; modules run in same shell so globals suffice.

  # after computing MD5_EXCL, META_EXCL, LOG_EXCL, RUN_BASENAME, FIRST_RUN_BASENAME, ALT_LOG_EXCL, LOCK_EXCL
  # Add all tool-generated basenames to EXCLUDE_PATTERNS so find_file_expr's basename filtering excludes them.
  # IMPORTANT: do not exclude bare ALT_LOG_EXCL or ALT_LOG_EXCL.* (could match user files).
  # Only exclude the actual rotated log patterns to avoid skipping real data.
  EXCLUDE_PATTERNS+=("$MD5_EXCL" "$META_EXCL" "$LOG_EXCL" "$RUN_EXCL" "$FIRST_RUN_EXCL" "${ALT_LOG_EXCL}.log" "${ALT_LOG_EXCL}.*.log" "$LOCK_EXCL")
}

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
    ! -name "*${LOCK_SUFFIX}" \
    ! -name "$RUN_EXCL" \
    ! -name "$FIRST_RUN_EXCL" \
    ! -name "${ALT_LOG_EXCL}.log" \
    ! -name "${ALT_LOG_EXCL}.*.log" \
    -print0 | while IFS= read -r -d '' f; do
      local fname; fname=$(basename "$f")
      local skip=0

      # Apply exclude patterns first; these are shell globs evaluated with [[ .. == pattern ]]
      if [ "${EXCLUDE_PATTERNS:+1}" = "1" ] && [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
        for pat in "${EXCLUDE_PATTERNS[@]}"; do
          # shellcheck disable=SC2053
          [[ "$fname" == $pat ]] && skip=1 && break
        done
      fi

      # If include patterns are defined, require a match (after exclusions)
      if [ "$skip" -eq 0 ] && [ "${INCLUDE_PATTERNS:+1}" = "1" ] && [ "${#INCLUDE_PATTERNS[@]}" -gt 0 ]; then
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
