#!/usr/bin/env bash
# stat.sh
#
# Cross‑platform stat abstraction.
# v2.3 used separate get_inode/get_dev/get_mtime/get_size functions with GNU vs BSD branching.
# v2.4 simplifies this by detecting once at startup and caching format strings.
# Provides a single stat_field() wrapper for all calls, reducing duplicated code paths.

STAT_STYLE=""     # "gnu" or "bsd"
STAT_INODE=""     # format string for inode
STAT_DEV=""       # format string for device
STAT_MTIME=""     # format string for mtime
STAT_SIZE=""      # format string for size

detect_stat() {
  # Detect GNU stat via --version; otherwise assume BSD/macOS stat.
  if stat --version >/dev/null 2>&1; then
    STAT_STYLE="gnu"
    STAT_INODE="-c %i"
    STAT_DEV="-c %d"
    STAT_MTIME="-c %Y"
    STAT_SIZE="-c %s"
  else
    STAT_STYLE="bsd"
    STAT_INODE="-f %i"
    STAT_DEV="-f %d"
    STAT_MTIME="-f %m"
    STAT_SIZE="-f %z"
  fi
  dbg "Detected stat style: $STAT_STYLE"
}

# stat_field FILE FIELD
# FIELD = inode | dev | mtime | size
stat_field() {
  local file="$1" field="$2"
  case "$field" in
    inode) stat "$STAT_INODE" -- "$file" 2>/dev/null ;;
    dev)   stat "$STAT_DEV"   -- "$file" 2>/dev/null ;;
    mtime) stat "$STAT_MTIME" -- "$file" 2>/dev/null ;;
    size)  stat "$STAT_SIZE"  -- "$file" 2>/dev/null ;;
    *) echo "unknown field '$field'" >&2; return 1 ;;
  esac
}
