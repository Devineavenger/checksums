#!/usr/bin/env bash
# shellcheck disable=SC2034
# process.sh
# shellcheck source=lib/init.sh
# shellcheck source=lib/logging.sh
# shellcheck source=lib/hash.sh
#
# Per-directory processing: hashing, meta writing, reuse heuristics, and verify-only mode (2.2).
# Preserves the original flow while adding parallel hashing and inode-based reuse.
# v2.4: switched from get_inode/get_dev/get_mtime/get_size to stat_field (unified abstraction).
# v2.4: added compatibility path for Bash < 4 using text-map fallbacks when associative arrays are not available.
# v2.6: fixes
#   - Signature stability: pass meta lines to write_meta as individual args (not one giant string).
#   - Syntax: fix mismatched braces in DRY_RUN block.
#   - Robustness: initialize arrays in process_directories to avoid unbound variable errors.
#
# v2.7 (custom):
#   - Side-effect-free planning function for pre-summary.
#   - No skip logging in the decision loop (skip logs happen after confirmation in run_checksums).
#
# v3.0 (custom):
#   - Honor SKIP_EMPTY (default 1) to avoid creating .meta/.log/.md5 for empty or container-only directories.
#   - Early-return in process_single_directory before any per-directory side effects when skipping.
#   - Block side-effects in root when NO_ROOT_SIDEFILES=1.

process_single_directory() {
  local d="$1"

  # Absolute root guard: if NO_ROOT_SIDEFILES=1 and d is the run TARGET_DIR, do nothing.
  if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ -n "${TARGET_DIR:-}" ] && [ "$d" = "${TARGET_DIR%/}" ]; then
    return 0
  fi

  # Absolute early guard: skip if SKIP_EMPTY and no regular files anywhere under d.
  # This must happen before any filename derivation, logging, or side effects.
  if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "$FORCE_REBUILD" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
    if ! find "$d" -type f -print -quit 2>/dev/null | grep -q .; then
      # Do not set LOG_FILEPATH, do not touch any files
      return 0
    fi
  fi

  # Only derive filenames after we know the dir should be processed
  local sumf="$d/$MD5_FILENAME" metaf="$d/$META_FILENAME" logf="$d/$LOG_FILENAME"

  # Prepare per-directory log: rotate (2.1, keep only 2 in 2.3) and add audit run header (2.2)
  LOG_FILEPATH="$logf"
  if [ "$DRY_RUN" -eq 0 ]; then
    rotate_log "$LOG_FILEPATH"
    : > "$LOG_FILEPATH"
    log_run_header "$LOG_FILEPATH"
  fi

  log "Starting directory: $d"
  log "sumfile: $sumf  metafile: $metaf  logfile: $logf"

  # remove stale legacy lock if found (safe)
  if [ -f "${metaf}${LOCK_SUFFIX}" ]; then
    if [ ! -s "${metaf}${LOCK_SUFFIX}" ] || [ "$(find "${metaf}${LOCK_SUFFIX}" -mtime +0 -print 2>/dev/null)" ]; then
      dbg "Removing stale lock ${metaf}${LOCK_SUFFIX}"
      rm -f -- "${metaf}${LOCK_SUFFIX}" 2>/dev/null || dbg "Could not remove ${metaf}${LOCK_SUFFIX}"
    fi
  fi

  # If meta exists, verify signature; otherwise ignore/force rebuild
  if [ -f "$metaf" ] && ! verify_meta_sig "$metaf"; then
    record_error "Meta signature invalid for $metaf; ignoring meta and forcing rebuild"
    # In verify-only mode, we don't delete or rewrite; just record error and continue
    if [ "$VERIFY_ONLY" -eq 0 ]; then
      rm -f -- "$metaf" 2>/dev/null || record_error "Could not remove invalid meta $metaf"
    fi
  fi

  # Verification-only mode: do not write, only check md5 and meta
  if [ "$VERIFY_ONLY" -eq 1 ]; then
    local vmd5=2
    vmd5=$(verify_md5_file "$d")  # 0 ok, 1 mismatch, 2 missing
    if [ "$vmd5" -eq 0 ]; then
      log "Verify-only: MD5 OK for $d"
    elif [ "$vmd5" -eq 1 ]; then
      record_error "Verify-only: MD5 mismatches in $d"
    else
      record_error "Verify-only: MD5 file missing in $d"
    fi

    if [ -f "$metaf" ]; then
      if verify_meta_sig "$metaf"; then
        log "Verify-only: META signature OK for $d"
      else
        record_error "Verify-only: META signature invalid for $d"
      fi
    else
      log "Verify-only: META file missing in $d"
    fi

    count_verified=$((count_verified+1))
    log "Finished directory (verify-only): $d"
    LOG_FILEPATH=""
    return
  fi

  # Normal processing path
  read_meta "$metaf"

  local tmp_sum="${sumf}.tmp" tmp_meta="${metaf}.tmp"
  local -a files
  # Collect candidate files (NUL-delimited), sort for stable order
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find_file_expr "$d" | LC_ALL=C sort -z)

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: Would process ${#files[@]} files in $d"
  else
    : > "$tmp_sum" || { record_error "Cannot write $tmp_sum"; return; }
    : > "$tmp_meta" || { record_error "Cannot write $tmp_meta"; return; }
  fi

  # Build old manifest maps and inode-based cache (for hardlinks)
  # v2.4: dual approach depending on USE_ASSOC.
  declare -A old_path_by_inode old_mtime old_size old_hash
  declare -A inode_hash_cache  # inode:dev -> hash
  local MAP_old_path_by_inode MAP_old_mtime MAP_old_size MAP_old_hash MAP_inode_hash_cache
  if [ "${USE_ASSOC:-0}" -eq 0 ]; then
    MAP_old_path_by_inode="$(mktemp)"; : > "$MAP_old_path_by_inode"
    MAP_old_mtime="$(mktemp)"; : > "$MAP_old_mtime"
    MAP_old_size="$(mktemp)"; : > "$MAP_old_size"
    MAP_old_hash="$(mktemp)"; : > "$MAP_old_hash"
    MAP_inode_hash_cache="$(mktemp)"; : > "$MAP_inode_hash_cache"
  fi

  # Transfer meta data to our caches (associative or text maps)
  if [ "${USE_ASSOC:-0}" -eq 1 ]; then
    # shellcheck disable=SC2154    # meta_* arrays are populated by read_meta in lib/meta.sh
    for p in "${!meta_inode_dev[@]}"; do
      old_path_by_inode["${meta_inode_dev[$p]}"]="$p"
      old_mtime["$p"]="${meta_mtime[$p]}"
      old_size["$p"]="${meta_size[$p]}"
      old_hash["$p"]="${meta_hash_by_path[$p]}"
      inode_hash_cache["${meta_inode_dev[$p]}"]="${meta_hash_by_path[$p]}"
    done
  else
    # meta_* arrays exist only when Bash >= 4; for fallback, re-read meta file lines
    if [ -f "$metaf" ]; then
      while IFS=$'\t' read -r path inode dev mtime size hash; do
        [ -z "$path" ] && continue
        case "$path" in \#meta|\#sig|\#run) continue ;; esac
        map_set "$MAP_old_path_by_inode" "${inode}:${dev}" "$path"
        map_set "$MAP_old_mtime" "$path" "$mtime"
        map_set "$MAP_old_size" "$path" "$size"
        map_set "$MAP_old_hash" "$path" "$hash"
        map_set "$MAP_inode_hash_cache" "${inode}:${dev}" "$hash"
      done < "$metaf"
    fi
  fi

  # Collect tasks for hashing
  local results_file=""
  if [ "$DRY_RUN" -eq 0 ]; then
    results_file="$(mktemp "${TMPDIR:-/tmp}/hash_results.XXXXXX")" || results_file="$tmp_sum.hash.results"
    : > "$results_file"
  fi

  # These maps are per-run; dual storage based on USE_ASSOC
  declare -A path_to_hash  # path -> hash (filled for reused or after parallel)
  declare -A path_to_inode # path -> inode:dev
  declare -A path_to_meta  # path -> "fname<TAB>inode<TAB>dev<TAB>mtime<TAB>size"
  local MAP_path_to_hash MAP_path_to_inode MAP_path_to_meta
  if [ "${USE_ASSOC:-0}" -eq 0 ]; then
    MAP_path_to_hash="$(mktemp)"; : > "$MAP_path_to_hash"
    MAP_path_to_inode="$(mktemp)"; : > "$MAP_path_to_inode"
    MAP_path_to_meta="$(mktemp)"; : > "$MAP_path_to_meta"
  fi

  # Decide reuse vs compute; spawn parallel hash tasks
  for fpath in "${files[@]}"; do
    local fname inode dev mtime size inode_dev reuse h
    fname=$(basename "$fpath")
    inode=$(stat_field "$fpath" inode); dev=$(stat_field "$fpath" dev)
    mtime=$(stat_field "$fpath" mtime); size=$(stat_field "$fpath" size)
    inode_dev="${inode}:${dev}"
    reuse=0; h=""

    # Strong incremental by inode (renames and hardlinks)
    if [ "${USE_ASSOC:-0}" -eq 1 ]; then
      if [ -n "${inode_hash_cache[$inode_dev]:-}" ]; then
        if [ -n "${old_path_by_inode[$inode_dev]:-}" ]; then
          local oldp="${old_path_by_inode[$inode_dev]}"
          if [ "${old_mtime[$oldp]}" = "$mtime" ] && [ "${old_size[$oldp]}" = "$size" ]; then
            h="${inode_hash_cache[$inode_dev]}"; reuse=1
            log "Reusing hash via inode for $fname (inode=$inode_dev from $oldp)"
          fi
        fi
      fi
    else
      local oldp; oldp="$(map_get "$MAP_old_path_by_inode" "$inode_dev")"
      local cached; cached="$(map_get "$MAP_inode_hash_cache" "$inode_dev")"
      local om; om="$(map_get "$MAP_old_mtime" "$oldp")"
      local os; os="$(map_get "$MAP_old_size" "$oldp")"
      if [ -n "$cached" ] && [ -n "$oldp" ] && [ "$om" = "$mtime" ] && [ "$os" = "$size" ]; then
        h="$cached"; reuse=1
        log "Reusing hash via inode for $fname (inode=$inode_dev from $oldp)"
      fi
    fi

    # Fallback: reuse by same path if unchanged
    if [ "$reuse" -eq 0 ]; then
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        if [ -n "${meta_mtime[$fname]:-}" ] && [ "${meta_mtime[$fname]}" = "$mtime" ] && [ "${meta_size[$fname]}" = "$size" ]; then
          h="${meta_hash_by_path[$fname]}"; reuse=1
          inode_hash_cache["$inode_dev"]="$h"
          log "Reusing hash for unchanged file $fname"
        fi
      else
        # When using fallback, meta_* arrays may not exist; leverage text maps if available
        local mm ms mh
        mm="$(map_get "$MAP_old_mtime" "$fname")"
        ms="$(map_get "$MAP_old_size" "$fname")"
        mh="$(map_get "$MAP_old_hash" "$fname")"
        if [ -n "$mm" ] && [ "$mm" = "$mtime" ] && [ -n "$ms" ] && [ "$ms" = "$size" ] && [ -n "$mh" ]; then
          h="$mh"; reuse=1
          map_set "$MAP_inode_hash_cache" "$inode_dev" "$h"
          log "Reusing hash for unchanged file $fname"
        fi
      fi
    fi

    # Record inode, meta tuple, and hash (assoc vs text)
    if [ "${USE_ASSOC:-0}" -eq 1 ]; then
      path_to_inode["$fpath"]="$inode_dev"
      path_to_meta["$fpath"]="${fname}"$'\t'"${inode}"$'\t'"${dev}"$'\t'"${mtime}"$'\t'"${size}"
    else
      map_set "$MAP_path_to_inode" "$fpath" "$inode_dev"
      map_set "$MAP_path_to_meta" "$fpath" "${fname}"$'\t'"${inode}"$'\t'"${dev}"$'\t'"${mtime}"$'\t'"${size}"
    fi

    if [ "$reuse" -eq 1 ]; then
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        path_to_hash["$fpath"]="$h"
      else
        map_set "$MAP_path_to_hash" "$fpath" "$h"
      fi
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRYRUN: would hash $fpath with $PER_FILE_ALGO"
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        path_to_hash["$fpath"]=""
      else
        map_set "$MAP_path_to_hash" "$fpath" ""
      fi
    else
      _par_maybe_wait
      _do_hash_task "$fpath" "$PER_FILE_ALGO" "$results_file" &
      pids+=("$!")
      pids_count=${#pids[@]}
    fi
  done

  # Collect parallel results
  if [ "$DRY_RUN" -eq 0 ]; then
    _par_wait_all
    while IFS=$'\t' read -r rpath rhash; do
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        path_to_hash["$rpath"]="$rhash"
        local id="${path_to_inode[$rpath]}"
        [ -n "$id" ] && [ -n "$rhash" ] && inode_hash_cache["$id"]="$rhash"
      else
        map_set "$MAP_path_to_hash" "$rpath" "$rhash"
        local id; id="$(map_get "$MAP_path_to_inode" "$rpath")"
        [ -n "$id" ] && [ -n "$rhash" ] && map_set "$MAP_inode_hash_cache" "$id" "$rhash"
      fi
      local bname; bname=$(basename "$rpath")
      if [ -n "$rhash" ]; then
        log "Hashed $bname -> ${rhash:0:16}... (truncated)"
      else
        record_error "Hash failed for $rpath"
      fi
    done < "$results_file"
    rm -f -- "$results_file" 2>/dev/null || true
  fi

  # Write outputs
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "${USE_ASSOC:-0}" -eq 1 ]; then
      for fpath in "${files[@]}"; do
        local fname h meta_line
        fname=$(basename "$fpath")
        h="${path_to_hash[$fpath]}"
        meta_line="${path_to_meta[$fpath]}"$'\t'"$h"
        # Write filename with leading ./ to match standard md5sum format
        printf '%s  ./%s\n' "$h" "$fname" >> "$tmp_sum"
        printf '%s\n' "$meta_line" >> "$tmp_meta"
      done
    else
      for fpath in "${files[@]}"; do
        local fname h meta_line
        fname=$(basename "$fpath")
        h="$(map_get "$MAP_path_to_hash" "$fpath")"
        meta_line="$(map_get "$MAP_path_to_meta" "$fpath")"$'\t'"$h"
        # Write filename with leading ./ to match standard md5sum format
        printf '%s  ./%s\n' "$h" "$fname" >> "$tmp_sum"
        printf '%s\n' "$meta_line" >> "$tmp_meta"
      done
      # cleanup temp maps
      rm -f "$MAP_path_to_hash" "$MAP_path_to_inode" "$MAP_path_to_meta" 2>/dev/null || true
    fi

    local lockfile="${metaf}${LOCK_SUFFIX}"

    # IMPORTANT: preserve line boundaries when passing meta entries to write_meta.
    # Read tmp_meta into an array and expand as separate arguments.
    local -a meta_lines=()
    while IFS= read -r line; do
      meta_lines+=("$line")
    done < "$tmp_meta"

    with_lock "$lockfile" write_meta "$metaf" "${meta_lines[@]}"
    mv -f "$tmp_sum" "$sumf" || record_error "Failed to move $tmp_sum -> $sumf"
    log "Wrote $sumf and $metaf"
  fi

  # cleanup temp maps for old meta caches if used
  if [ "${USE_ASSOC:-0}" -eq 0 ]; then
    rm -f "$MAP_old_path_by_inode" "$MAP_old_mtime" "$MAP_old_size" "$MAP_old_hash" "$MAP_inode_hash_cache" 2>/dev/null || true
  fi

  log "Finished directory: $d"
  LOG_FILEPATH=""
}

# Note: decide_directories_plan intentionally lives in lib/planner.sh
