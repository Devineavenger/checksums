#!/usr/bin/env bash
# stat.sh
#
# Cross‑platform stat abstraction.
# v2.3 used separate get_inode/get_dev/get_mtime/get_size functions with GNU vs BSD branching.
# v2.4 simplifies this by detecting once at startup and caching format strings.
# Provides a single stat_field() wrapper for all calls, reducing duplicated code paths.

# Combined format string: fetch inode, dev, mtime, size in a single stat call.
# This reduces per-file subprocess overhead (4 calls -> 1 call).
STAT_STYLE=""     # "gnu" or "bsd"
STAT_FMT=""       # combined format string for inode:dev:mtime:size

 detect_stat() {
  # Detect GNU stat via --version; otherwise assume BSD/macOS stat.
  if stat --version >/dev/null 2>&1; then
    STAT_STYLE="gnu"
    STAT_FMT="-c %i:%d:%Y:%s"
  else
    STAT_STYLE="bsd"
    STAT_FMT="-f %i:%d:%m:%z"
  fi
  dbg "Detected stat style: $STAT_STYLE"
}

# stat_all_fields FILE
# Returns: inode<TAB>dev<TAB>mtime<TAB>size
# This replaces multiple stat_field calls with a single stat invocation (SC1073/SC1072 fix).
# Combined fetch: returns TAB-delimited inode,dev,mtime,size (or non-zero on failure).
# Replace multiple stat_field calls with stat_all_fields in hot paths (e.g., process.sh).
stat_all_fields() {
  local file="$1"
  local out
  out=$(stat "$STAT_FMT" -- "$file" 2>/dev/null) || return 1
  IFS=":" read -r inode dev mtime size <<<"$out"
  printf '%s\t%s\t%s\t%s\n' "$inode" "$dev" "$mtime" "$size"
}