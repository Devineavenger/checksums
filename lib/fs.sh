#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

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

# _sidecar_path DIR FILENAME
# Return the path for a sidecar file. When STORE_DIR is set, maps the directory
# into the central store (mirror tree layout); otherwise returns DIR/FILENAME.
_sidecar_path() {
  local dir="$1" filename="$2"
  if [ -n "${STORE_DIR:-}" ]; then
    local target="${TARGET_DIR%/}"
    local rel="${dir#"$target"}"
    rel="${rel#/}"
    local store_sub
    if [ -z "$rel" ]; then
      store_sub="${STORE_DIR%/}"
    else
      store_sub="${STORE_DIR%/}/$rel"
    fi
    mkdir -p "$store_sub" 2>/dev/null || true
    printf '%s/%s' "$store_sub" "$filename"
  else
    printf '%s/%s' "$dir" "$filename"
  fi
}

# _runlog_path FILENAME
# Return the path for a run-level log file (run.log, first-run.log).
# When STORE_DIR is set, places it in the store root; otherwise in TARGET_DIR.
_runlog_path() {
  local filename="$1"
  if [ -n "${STORE_DIR:-}" ]; then
    printf '%s/%s' "${STORE_DIR%/}" "$filename"
  else
    printf '%s/%s' "${TARGET_DIR%/}" "$filename"
  fi
}

_safe_name() {
  # Return a safe non-matching name if input empty to prevent accidental
  # -name "" constructs in find which can produce warnings or unintended matches.
  local n="$1"
  [ -n "$n" ] && printf '%s' "$n" || printf '%s' '__DO_NOT_MATCH__'
}

# _find — wrapper around find(1) that follows symlinks when FOLLOW_SYMLINKS=1.
# When enabled, prepends -L so symlinked files match -type f and symlinked
# directories are descended into. All file/directory discovery commands should
# use _find instead of find directly so the flag is honored uniformly.
_find() {
  if [ "${FOLLOW_SYMLINKS:-0}" -eq 1 ]; then
    command find -L "$@"
  else
    command find "$@"
  fi
}

# Ensure derived exclusion names are available even if build_exclusions() hasn't been run.
# This makes the helpers safe to call in isolation (interactive tests, unit probes).
# We provide safe defaults here to avoid unbound variables under `set -u`.
SUM_EXCL="${SUM_EXCL:-$(_safe_name "$(basename "${SUM_FILENAME:-#####checksums#####.md5}")")}"
# Multi-algo exclusion array: safe default mirrors SUM_EXCL for single-algo (populated by build_exclusions)
if [ -z "${SUM_EXCLS+x}" ]; then SUM_EXCLS=("$SUM_EXCL"); fi
META_EXCL="${META_EXCL:-$(_safe_name "$(basename "${META_FILENAME:-#####checksums#####.meta}")")}"
LOG_EXCL="${LOG_EXCL:-$(_safe_name "$(basename "${LOG_FILENAME:-#####checksums#####.log}")")}"
ALT_LOG_EXCL="${ALT_LOG_EXCL:-$(_safe_name "$(basename "${LOG_BASE:-#####checksums#####}")")}"
RUN_EXCL="${RUN_EXCL:-$(_safe_name "$(basename "${LOG_BASE:-#####checksums#####}.run.log")")}"
FIRST_RUN_EXCL="${FIRST_RUN_EXCL:-$(_safe_name "$(basename "${LOG_BASE:-#####checksums#####}.first-run.log")")}"
LOCK_EXCL="${LOCK_EXCL:-$(_safe_name "${LOCK_SUFFIX:-.lock}")}"
STORE_DIR_EXCL="${STORE_DIR_EXCL:-}"

# Default pattern arrays: ensure they exist as proper global arrays so set -u
# doesn't trip on them and ${#arr[@]} returns 0 (not 1 with an empty element).
# Uses -ga (global array) so declarations survive bats load context (function scope).
declare -p EXCLUDE_PATTERNS &>/dev/null || declare -ga EXCLUDE_PATTERNS=()
declare -p INCLUDE_PATTERNS &>/dev/null || declare -ga INCLUDE_PATTERNS=()

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
# Called from process.sh (batch thresholds) and args.sh (size filter validation).
to_bytes() {
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
  _find "$d" -type f -print0 2>/dev/null
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
    # Multi-algo: check against all manifest exclusions (SUM_EXCLS)
    local _is_sum=0 _se
    for _se in "${SUM_EXCLS[@]}"; do
      [ "$fname" = "$_se" ] && { _is_sum=1; break; }
    done
    [ "$_is_sum" -eq 1 ] && continue
    case "$fname" in
      "$META_EXCL" | "$LOG_EXCL" ) continue ;;
      # rotated logs: base.<ts>.log (tolerate legacy variants too)
      ${ALT_LOG_EXCL}.*.log ) continue ;;
      # run-level and first-run logs (explicit names — match literally)
      "$RUN_EXCL" | "$FIRST_RUN_EXCL" ) continue ;;
      # lock suffix
      *"$LOCK_SUFFIX") continue ;;
      # If the basename matches any EXCLUDE_PATTERNS, treat as excluded too
      *)
        # Apply user-supplied exclude patterns (basename glob matching)
        if [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
          local pat
          for pat in "${EXCLUDE_PATTERNS[@]}"; do
            # shellcheck disable=SC2053
            [[ "$fname" == $pat ]] && { fname=""; break; }
          done
          [ -z "$fname" ] && continue
        fi
        # If include patterns are defined, require a match (allowlist)
        if [ "${#INCLUDE_PATTERNS[@]}" -gt 0 ]; then
          local ipat imatch=0
          for ipat in "${INCLUDE_PATTERNS[@]}"; do
            # shellcheck disable=SC2053
            [[ "$fname" == $ipat ]] && { imatch=1; break; }
          done
          [ "$imatch" -eq 0 ] && continue
        fi
        # Apply size filters (skip files outside the specified range)
        if [ "${MAX_SIZE_BYTES:-0}" -gt 0 ] || [ "${MIN_SIZE_BYTES:-0}" -gt 0 ]; then
          local fsize
          fsize=$(_get_file_size "$f")
          if [ -n "$fsize" ]; then
            [ "${MAX_SIZE_BYTES:-0}" -gt 0 ] && [ "$fsize" -gt "$MAX_SIZE_BYTES" ] && continue
            [ "${MIN_SIZE_BYTES:-0}" -gt 0 ] && [ "$fsize" -lt "$MIN_SIZE_BYTES" ] && continue
          fi
        fi
        # Found a non-tool regular file matching all filters — return success.
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
    # Multi-algo: check against all manifest exclusions (SUM_EXCLS)
    local _is_sum=0 _se
    for _se in "${SUM_EXCLS[@]}"; do
      [ "$fname" = "$_se" ] && { _is_sum=1; break; }
    done
    [ "$_is_sum" -eq 1 ] && continue
    case "$fname" in
      "$META_EXCL" | "$LOG_EXCL" ) continue ;;
      ${ALT_LOG_EXCL}.*.log ) continue ;;
      "$RUN_EXCL" | "$FIRST_RUN_EXCL" ) continue ;;
      *"$LOCK_SUFFIX") continue ;;
      *)
        # Apply user-supplied exclude patterns (basename glob matching)
        if [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
          local pat skip=0
          for pat in "${EXCLUDE_PATTERNS[@]}"; do
            # shellcheck disable=SC2053
            [[ "$fname" == $pat ]] && skip=1 && break
          done
          [ "$skip" -eq 1 ] && continue
        fi
        # If include patterns are defined, require a match (allowlist)
        if [ "${#INCLUDE_PATTERNS[@]}" -gt 0 ]; then
          local ipat imatch=0
          for ipat in "${INCLUDE_PATTERNS[@]}"; do
            # shellcheck disable=SC2053
            [[ "$fname" == $ipat ]] && { imatch=1; break; }
          done
          [ "$imatch" -eq 0 ] && continue
        fi
        # Apply size filters (skip files outside the specified range)
        if [ "${MAX_SIZE_BYTES:-0}" -gt 0 ] || [ "${MIN_SIZE_BYTES:-0}" -gt 0 ]; then
          local fsize
          fsize=$(_get_file_size "$f")
          if [ -n "$fsize" ]; then
            [ "${MAX_SIZE_BYTES:-0}" -gt 0 ] && [ "$fsize" -gt "$MAX_SIZE_BYTES" ] && continue
            [ "${MIN_SIZE_BYTES:-0}" -gt 0 ] && [ "$fsize" -lt "$MIN_SIZE_BYTES" ] && continue
          fi
        fi
        return 0
        ;;
    esac
  done < <(_find "$d" -maxdepth 1 -type f -print0 2>/dev/null)
  return 1
}

build_exclusions() {
  # Strip directory components so only basenames are compared in find expressions.
  # This mirrors original behavior which avoided full-path matches for rotated logs.
  SUM_EXCL=$(_safe_name "$(basename "$SUM_FILENAME")")
  META_EXCL=$(_safe_name "$(basename "$META_FILENAME")")
  LOG_EXCL=$(_safe_name "$(basename "$LOG_FILENAME")")
  RUN_EXCL=$(_safe_name "$(basename "${LOG_BASE:-$BASE_NAME}.run.log")")
  FIRST_RUN_EXCL=$(_safe_name "$(basename "${LOG_BASE:-$BASE_NAME}.first-run.log")")
  # ALT_LOG_EXCL is the log base without the .log suffix so rotated logs can be matched as:
  #   <ALT_LOG_EXCL>.<timestamp>.log
  ALT_LOG_EXCL=$(_safe_name "$(basename "${LOG_BASE:-$BASE_NAME}")")
  LOCK_EXCL="${META_EXCL}${LOCK_SUFFIX}"
  # Note: we intentionally don't export these; modules run in same shell so globals suffice.

  # Multi-algo: derive exclusion basenames for each algorithm's manifest.
  # SUM_EXCLS holds the per-algo basenames for use in find_file_expr, has_files, and planner.
  SUM_EXCLS=()
  local _sf
  for _sf in "${SUM_FILENAMES[@]}"; do
    SUM_EXCLS+=("$(_safe_name "$(basename "$_sf")")")
  done

  # Central store exclusion: when STORE_DIR is inside TARGET_DIR, record it for pruning.
  STORE_DIR_EXCL=""
  if [ -n "${STORE_DIR:-}" ] && [ -n "${TARGET_DIR:-}" ]; then
    local _sd_abs="${STORE_DIR%/}"
    local _td_abs="${TARGET_DIR%/}"
    case "$_sd_abs" in
      "$_td_abs"/*)
        STORE_DIR_EXCL="$_sd_abs"
        ;;
    esac
  fi

  # after computing SUM_EXCL, META_EXCL, LOG_EXCL, RUN_EXCL, FIRST_RUN_EXCL, ALT_LOG_EXCL, LOCK_EXCL
  # Add all tool-generated basenames to EXCLUDE_PATTERNS so find_file_expr's basename filtering excludes them.
  # IMPORTANT: do not exclude bare ALT_LOG_EXCL or ALT_LOG_EXCL.* (could match user files).
  # Only exclude the actual rotated log patterns to avoid skipping real data.
  # Multi-algo: add all manifest basenames (SUM_EXCLS) instead of just the primary SUM_EXCL.
  EXCLUDE_PATTERNS+=("${SUM_EXCLS[@]}" "$META_EXCL" "$LOG_EXCL" "$RUN_EXCL" "$FIRST_RUN_EXCL" "${ALT_LOG_EXCL}.log" "${ALT_LOG_EXCL}.*.log" "$LOCK_EXCL")
}

# _get_file_size FILE
# Print the file size in bytes. Uses stat when available (set by detect_stat
# in stat.sh), falls back to wc -c for portability in test harnesses that
# source fs.sh directly without loading stat.sh.
# Prints empty string on failure.
_get_file_size() {
  local f="$1" sz
  if [ -n "${STAT_FLAG:-}" ] && [ -n "${STAT_SIZE:-}" ]; then
    sz=$(stat "$STAT_FLAG" "$STAT_SIZE" -- "$f" 2>/dev/null) || sz=""
  else
    sz=$(wc -c < "$f" 2>/dev/null) || sz=""
    sz="${sz// /}"
  fi
  printf '%s' "$sz"
}

find_file_expr() {
  # Emit NUL-delimited list of regular files in the provided directory that are
  # candidates for inclusion in the per-directory checksum manifest.
  # Exclusions applied:
  #  - common OS metadata files (.DS_Store, Apple resource forks)
  #  - tool-generated artifacts like .md5/.sha256/.meta/.log and rotated logs
  #  - user-supplied EXCLUDE_PATTERNS (applied to the basename)
  #  - if INCLUDE_PATTERNS is non-empty, only matching basenames are allowed
  local d="$1"
  # Build dynamic exclusion args for all manifest filenames (multi-algo support)
  local -a _sum_excl_args=()
  local _se
  for _se in "${SUM_EXCLS[@]}"; do
    _sum_excl_args+=(! -name "$_se")
  done
  _find "$d" -maxdepth 1 -type f \
    ! -name '.DS_Store' ! -name '._*' \
    "${_sum_excl_args[@]}" \
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
      if [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
        for pat in "${EXCLUDE_PATTERNS[@]}"; do
          # shellcheck disable=SC2053
          [[ "$fname" == $pat ]] && skip=1 && break
        done
      fi

      # If include patterns are defined, require a match (allowlist; after exclusions)
      if [ "$skip" -eq 0 ] && [ "${#INCLUDE_PATTERNS[@]}" -gt 0 ]; then
        local match=0
        for pat in "${INCLUDE_PATTERNS[@]}"; do
          # shellcheck disable=SC2053
          [[ "$fname" == $pat ]] && match=1 && break
        done
        [ "$match" -eq 0 ] && skip=1
      fi

      # Apply size filters (only stat if at least one threshold is active)
      if [ "$skip" -eq 0 ] && { [ "${MAX_SIZE_BYTES:-0}" -gt 0 ] || [ "${MIN_SIZE_BYTES:-0}" -gt 0 ]; }; then
        local fsize
        fsize=$(_get_file_size "$f")
        if [ -n "$fsize" ]; then
          [ "${MAX_SIZE_BYTES:-0}" -gt 0 ] && [ "$fsize" -gt "$MAX_SIZE_BYTES" ] && skip=1
          [ "${MIN_SIZE_BYTES:-0}" -gt 0 ] && [ "$fsize" -lt "$MIN_SIZE_BYTES" ] && skip=1
        fi
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
  _find "$base_dir" -type f -name "*${LOCK_SUFFIX}" -print0 2>/dev/null \
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
