#!/usr/bin/env bash
# stat.sh
#
# Cross‑platform stat abstraction.
# Detect once (GNU vs BSD/macOS) and expose both:
#   - stat_all_fields(file) => inode<TAB>dev<TAB>mtime<TAB>size from a single call
#   - stat_field(file, field) => single field for callers that prefer granular access
# This unifies mixed callers in planner/process and avoids brace parsing issues flagged by ShellCheck.

# Combined format string: fetch inode, dev, mtime, size in a single stat call.
# This reduces per-file subprocess overhead (4 calls -> 1 call).
STAT_STYLE=""     # "gnu" or "bsd"
STAT_FMT=""       # combined format string for inode:dev:mtime:size
STAT_INODE=""     # single-field formats retained for compatibility
STAT_DEV=""
STAT_MTIME=""
STAT_SIZE=""

detect_stat() {
   # Detect GNU stat via --version; otherwise assume BSD/macOS stat.
   if stat --version >/dev/null 2>&1; then
     STAT_STYLE="gnu"
     STAT_FMT="-c %i:%d:%Y:%s"
    STAT_INODE="-c %i"
    STAT_DEV="-c %d"
    STAT_MTIME="-c %Y"
    STAT_SIZE="-c %s"
   else
     STAT_STYLE="bsd"
     STAT_FMT="-f %i:%d:%m:%z"
    STAT_INODE="-f %i"
    STAT_DEV="-f %d"
    STAT_MTIME="-f %m"
    STAT_SIZE="-f %z"
   fi
   dbg "Detected stat style: $STAT_STYLE"
 }

# Combined fetch: returns TAB-delimited inode,dev,mtime,size (or non-zero on failure).
# Prefer this in hot paths to reduce subprocess overhead (4 calls -> 1).
 stat_all_fields() {
   local file="$1"
   local out
   out=$(stat "$STAT_FMT" -- "$file" 2>/dev/null) || return 1
   IFS=":" read -r inode dev mtime size <<<"$out"
   printf '%s\t%s\t%s\t%s\n' "$inode" "$dev" "$mtime" "$size"
 }

# Single-field wrapper for compatibility with existing callers (planner).
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