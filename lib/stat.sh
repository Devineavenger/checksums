#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# stat.sh
#
# Cross‑platform stat abstraction.
# Detect once (GNU vs BSD/macOS) and expose both:
#   - stat_all_fields(file) => inode<TAB>dev<TAB>mtime<TAB>size from a single call
#   - stat_field(file, field) => single field for callers that prefer granular access
# This unifies mixed callers in planner/process and avoids brace parsing issues flagged by ShellCheck.

# Combined format string: fetch inode, dev, mtime, size in a single stat call.
# This reduces per-file subprocess overhead (4 calls -> 1 call).
STAT_STYLE=""     # "gnu" or "bsd" or "fallback"
STAT_FLAG=""      # option flag: -c (GNU) or -f (BSD)
STAT_FMT=""       # combined format string for inode:dev:mtime:size (no flag)
STAT_INODE=""     # single-field format strings (no flag)
STAT_DEV=""
STAT_MTIME=""
STAT_SIZE=""

detect_stat() {
  # Prefer feature probes over --version, but use the same format strings.
  # STAT_FLAG is stored separately from the format string so each call site
  # passes them as two distinct arguments: stat "$STAT_FLAG" "$STAT_FMT" ...
  # Bundling them into one variable and quoting it would pass a single arg
  # with a leading space in the format, corrupting inode/dev parsing.
  if stat -c %i . >/dev/null 2>&1; then
    STAT_STYLE="gnu"
    STAT_FLAG="-c"
    STAT_FMT="%i:%d:%Y:%s"
    STAT_INODE="%i"
    STAT_DEV="%d"
    STAT_MTIME="%Y"
    STAT_SIZE="%s"
  elif stat -f %i . >/dev/null 2>&1; then
    STAT_STYLE="bsd"
    STAT_FLAG="-f"
    STAT_FMT="%i:%d:%m:%z"
    STAT_INODE="%i"
    STAT_DEV="%d"
    STAT_MTIME="%m"
    STAT_SIZE="%z"
  else
    STAT_STYLE="fallback"
    STAT_FLAG=""
    STAT_FMT=""
  fi
  dbg "Detected stat style: $STAT_STYLE"
}

# Cache for stat_all_fields results to avoid repeated subprocess calls.
declare -gA STAT_CACHE=()

# Combined fetch: returns TAB-delimited inode,dev,mtime,size (or non-zero on failure).
# Uses STAT_CACHE to avoid repeated stat calls.
stat_all_fields() {
  local file="$1"

  # Return cached result if present
  if [ -n "${STAT_CACHE[$file]:-}" ]; then
    printf '%s\n' "${STAT_CACHE[$file]}"
    return 0
  fi

  local line=""
  case "$STAT_STYLE" in
    gnu|bsd)
      local out inode dev mtime size
      out=$(stat "$STAT_FLAG" "$STAT_FMT" -- "$file" 2>/dev/null) || out=""
      if [ -z "$out" ]; then
        inode=$(stat_field "$file" inode 2>/dev/null || echo 0)
        dev=$(stat_field   "$file" dev   2>/dev/null || echo 0)
        mtime=$(stat_field "$file" mtime 2>/dev/null || echo 0)
        size=$(stat_field  "$file" size  2>/dev/null || echo 0)
      else
        IFS=":" read -r inode dev mtime size <<<"$out"
      fi
      line=$(printf '%s\t%s\t%s\t%s\n' "${inode:-0}" "${dev:-0}" "${mtime:-0}" "${size:-0}")
      ;;
    fallback)
      local inode dev mtime size
      inode=$(stat_field "$file" inode 2>/dev/null || echo 0)
      dev=$(stat_field   "$file" dev   2>/dev/null || echo 0)
      mtime=$(stat_field "$file" mtime 2>/dev/null || echo 0)
      size=$(stat_field  "$file" size  2>/dev/null || echo 0)
      line=$(printf '%s\t%s\t%s\t%s\n' "${inode:-0}" "${dev:-0}" "${mtime:-0}" "${size:-0}")
      ;;
  esac

  STAT_CACHE["$file"]="$line"
  printf '%s' "$line"
}

# Single-field wrapper for compatibility with existing callers (planner).
# FIELD = inode | dev | mtime | size
stat_field() {
  local file="$1" field="$2"
  case "$field" in
    inode) stat "$STAT_FLAG" "$STAT_INODE" -- "$file" 2>/dev/null ;;
    dev)   stat "$STAT_FLAG" "$STAT_DEV"   -- "$file" 2>/dev/null ;;
    mtime) stat "$STAT_FLAG" "$STAT_MTIME" -- "$file" 2>/dev/null ;;
    size)  stat "$STAT_FLAG" "$STAT_SIZE"  -- "$file" 2>/dev/null ;;
    *) echo "unknown field '$field'" >&2; return 1 ;;
  esac
}