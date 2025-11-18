#!/usr/bin/env bash
# compat.sh
#
# Shell compatibility helpers.
# v2.4 adds detection of Bash version and fallback map functions for Bash < 4.
# Associative arrays are used when available; otherwise, we emulate maps with text files.
# This preserves behavior while ensuring portability to older macOS (Bash 3.2).

# shellcheck disable=SC2034
USE_ASSOC=1   # 1 = use associative arrays, 0 = fallback text maps

check_bash_version() {
  local major=${BASH_VERSINFO[0]:-0}
  if [ "$major" -lt 4 ]; then
    USE_ASSOC=0
    log "Bash < 4 detected (version $major), using POSIX text-map fallback"
  else
    USE_ASSOC=1
  fi
}

# Fallback map functions (text-file based)
# Each map is stored in a temp file with lines "key:value"
# For performance, these are only used when USE_ASSOC=0.

map_set() {
  local mapfile="$1" key="$2" val="$3"
  # Protect map updates with file lock when available to avoid lost updates.
  if [ "${TOOL_flock:-0}" -eq 1 ]; then
    # shellcheck disable=SC2016  # $1/$2/$3 are for the child sh -c, not this shell
    with_lock "$mapfile.lock" sh -c '
      set -e
      mapfile="$1"; key="$2"; val="$3"
      grep -v "^$key:" "$mapfile" 2>/dev/null > "$mapfile.tmp" || true
      mv -f "$mapfile.tmp" "$mapfile" 2>/dev/null || true
      printf "%s:%s\n" "$key" "$val" >> "$mapfile"
    ' _ "$mapfile" "$key" "$val"
  else
    grep -v "^$key:" "$mapfile" 2>/dev/null > "$mapfile.tmp" || true
    mv -f "$mapfile.tmp" "$mapfile" 2>/dev/null || true
    printf "%s:%s\n" "$key" "$val" >> "$mapfile"
  fi
}

map_get() {
  local mapfile="$1" key="$2"
  if [ "${TOOL_flock:-0}" -eq 1 ]; then
    # Use lock for a consistent snapshot and print only once
    # shellcheck disable=SC2016
    with_lock "$mapfile.lock" sh -c 'grep "^$1:" "$0" 2>/dev/null | cut -d: -f2-' "$mapfile" "$key"
  else
    grep "^$key:" "$mapfile" 2>/dev/null | cut -d: -f2-
  fi
}

map_del() {
  local mapfile="$1" key="$2"
  if [ "${TOOL_flock:-0}" -eq 1 ]; then
    # shellcheck disable=SC2016  # $1/$2 are for the child sh -c, not this shell
    with_lock "$mapfile.lock" sh -c '
      mapfile="$1"; key="$2"
      grep -v "^$key:" "$mapfile" 2>/dev/null > "$mapfile.tmp" || true
      mv -f "$mapfile.tmp" "$mapfile" 2>/dev/null || true
    ' _ "$mapfile" "$key"
  else
    grep -v "^$key:" "$mapfile" 2>/dev/null > "$mapfile.tmp" || true
    mv -f "$mapfile.tmp" "$mapfile" 2>/dev/null || true
  fi
}
