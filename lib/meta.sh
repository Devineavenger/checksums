#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# shellcheck disable=SC2034
# meta.sh
#
# Meta manifest handling: read/write, signature verification, and locking.
#
# v2.2: added audit trail #run lines appended to meta on write.
# v2.4: kept behavior intact and added no new changes here beyond stat_field usage in readers.
# v2.6: signature stability and diagnosability:
#       - Signature covers only stable data lines (exclude entries, etc.), not #meta/#run/#sig.
#       - Canonicalization: lines trimmed, sorted, LF-only, LC_ALL=C.
#       - Fixed awk filtering (no \b — awk treats \b as backspace, not word boundary).
#       - Added debug dump of canonical signed material to aid troubleshooting.

META_HEADER="#meta"; META_VER="v1"

# Dump the canonical material that is signed/verified (for debugging).
# Writes to RUN_LOG when DEBUG>0.
_meta_debug_dump() {
  local label="$1"; shift
  local tmpfile="$1"
  if [ "${DEBUG:-0}" -gt 0 ] && [ -n "$RUN_LOG" ] && [ -f "$tmpfile" ]; then
    {
      echo "---- META CANONICAL (${label}) BEGIN ----"
      # Hex + char view to catch invisible differences (CR, tabs, trailing spaces)
      od -An -tx1 -c "$tmpfile"
      echo "---- META CANONICAL (${label}) END ----"
    } >>"$RUN_LOG"
  fi
}

# Produce canonical content from a meta file: only stable data lines, trimmed, sorted.
# IMPORTANT: Do not use \b in awk; awk's \b is backspace, not a word boundary.
_meta_canonical_from_file() {
  local src="$1" canon="$2"
  # Keep only non-volatile lines, trim trailing spaces, normalize to LF, sort
  LC_ALL=C awk '!(/^#meta/ || /^#run/ || /^#sig/) { sub(/[ \t]+$/, "", $0); print }' "$src" \
    | LC_ALL=C sort >"$canon"
}

# Produce canonical content from in-memory data lines (exclude entries) we’re about to write.
_meta_canonical_from_lines() {
  local canon="$1"; shift
  # Normalize: trim trailing spaces and sort using awk, not Bash parameter expansion
  # (Bash ${var%%[[:space:]]} does not trim what you expect).
  {
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } | LC_ALL=C awk '{ sub(/[ \t]+$/, "", $0); print }' \
    | LC_ALL=C sort >"$canon"
}

read_meta() {
  local meta="$1"
  [ -f "$meta" ] || return 0
  # Bash 3.x (macOS) does not support associative arrays. Guard the declaration
  # and let downstream modules use their text-map fallbacks when arrays aren’t available.
  if declare -p -A >/dev/null 2>&1; then
    # Bash ≥ 4: use associative arrays for fast lookups.
    declare -gA meta_hash_by_path meta_mtime meta_size meta_inode_dev meta_path_by_inode
    meta_hash_by_path=(); meta_mtime=(); meta_size=(); meta_inode_dev=(); meta_path_by_inode=()
    while IFS=$'\t' read -r path inode dev mtime size hash; do
      [ -z "$path" ] && continue
      case "$path" in \#meta|\#sig|\#run) continue ;; # skip headers/signature and audit lines
      esac
      meta_hash_by_path["$path"]="$hash"
      meta_mtime["$path"]="$mtime"
      meta_size["$path"]="$size"
      meta_inode_dev["$path"]="${inode}:${dev}"
      meta_path_by_inode["${inode}:${dev}"]="$path"
    done < "$meta"
  else
    # Bash < 4: do not populate arrays here. process.sh and planner.sh already
    # implement non-assoc text-map fallbacks by re-reading the meta file as needed.
    :
  fi
}

verify_meta_sig() {
  local meta="$1" tmp stored expected
  [ -f "$meta" ] || return 0
  [ "$META_SIG_ALGO" = "none" ] && return 0
  stored=$(awk -F'\t' '/^#sig\t/ {print $2; exit}' "$meta" 2>/dev/null)
  [ -z "$stored" ] && return 0
  tmp=$(mktemp) || return 2

  # Build canonical verification content from file (drop #meta/#run/#sig)
  _meta_canonical_from_file "$meta" "$tmp"
  _meta_debug_dump "verify" "$tmp"

  # Hash canonical content with controlled locale
  if [ "$META_SIG_ALGO" = "sha256" ]; then
    if command -v sha256sum >/dev/null 2>&1; then expected=$(LC_ALL=C sha256sum <"$tmp" | awk '{print $1}')
    else expected=$(LC_ALL=C shasum -a 256 <"$tmp" | awk '{print $1}'); fi
  else
    if command -v md5sum >/dev/null 2>&1; then expected=$(LC_ALL=C md5sum <"$tmp" | awk '{print $1}')
    else expected=$(LC_ALL=C md5 <"$tmp" 2>/dev/null | awk '{print $1}'); fi
  fi
  rm -f "$tmp"
  [ "$expected" = "$stored" ]
}

write_meta() {
  # Writes meta manifest atomically, signs it (unless none), and appends audit trail.
  local meta="$1"; shift
  local tmp="${meta}.tmp" sig sigsrc

  # Write header with version and timestamp (not included in signature)
  printf '%s\t%s\t%s\n' "$META_HEADER" "$META_VER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp"

  # Write all provided data lines (exclude entries, etc.)
  for line in "$@"; do printf '%s\n' "$line" >>"$tmp"; done

  # Compute signature over canonical stable content only (exclude #meta/#run/#sig)
  if [ "$META_SIG_ALGO" != "none" ]; then
    sigsrc=$(mktemp) || { record_error "Failed to create temp for signature"; return 1; }
    _meta_canonical_from_lines "$sigsrc" "$@"
    _meta_debug_dump "write" "$sigsrc"

    if [ "$META_SIG_ALGO" = "sha256" ]; then
      if command -v sha256sum >/dev/null 2>&1; then sig=$(LC_ALL=C sha256sum <"$sigsrc" | awk '{print $1}')
      else sig=$(LC_ALL=C shasum -a 256 <"$sigsrc" | awk '{print $1}'); fi
    else
      if command -v md5sum >/dev/null 2>&1; then sig=$(LC_ALL=C md5sum <"$sigsrc" | awk '{print $1}')
      else sig=$(LC_ALL=C md5 <"$sigsrc" 2>/dev/null | awk '{print $1}'); fi
    fi
    rm -f "$sigsrc"
  fi

  # Append audit trail (2.2): record run id and timestamp (not included in signature)
  printf '#run\t%s\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$tmp"

  # Append signature as final line unless disabled
  if [ "$META_SIG_ALGO" != "none" ] && [ -n "$sig" ]; then
    printf '#sig\t%s\n' "$sig" >>"$tmp"
  fi

  mv -f "$tmp" "$meta" || { record_error "Failed to move $tmp -> $meta"; return 1; }
  return 0
}

with_lock() {
  # Use flock if available; no persistent lockfiles.
  local lockfile="$1"; shift
  # shellcheck disable=SC2154
  if [ "$TOOL_flock" -eq 1 ]; then
    # Ensure parent directory exists and allocate a descriptor safely.
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true
    : > "$lockfile" 2>/dev/null || true
    # Open fd 9 for the duration of the command; ensure we don't leak if open fails.
    if exec 9> "$lockfile"; then
      flock -x 9
      # run the command while holding the lock
      "$@"
      # release and close fd 9 (use eval to avoid shells that don't support exec 9>&- directly)
      flock -u 9
      eval "exec 9>&-" || true
      # Do not remove the lockfile here; leaving it is safe and avoids races with other openers.
    else
      # Fallback: run without lock but record a warning
      record_error "Warning: could not open lockfile descriptor for $lockfile; running without lock"
      "$@"
    fi
  else
    record_error "Warning: flock not available; running without file locks (race possible)."
    "$@"
  fi
}
