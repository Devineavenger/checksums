# process.sh
# Per-directory processing: hashing, meta writing, reuse heuristics, and verify-only mode (2.2).
# Preserves the original flow while adding parallel hashing and inode-based reuse.

process_single_directory() {
  local d="$1"
  local sumf="$d/$MD5_FILENAME" metaf="$d/$META_FILENAME" logf="$d/$LOG_FILENAME"

  # Prepare per-directory log: rotate (2.1) and add audit run header (2.2)
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
  if [ -f "$metaf" ]; then
    if ! verify_meta_sig "$metaf"; then
      record_error "Meta signature invalid for $metaf; ignoring meta and forcing rebuild"
      # In verify-only mode, we don't delete or rewrite; just record error and continue
      if [ "$VERIFY_ONLY" -eq 0 ]; then
        rm -f -- "$metaf" 2>/dev/null || record_error "Could not remove invalid meta $metaf"
      fi
    fi
  fi

  # Verification-only mode: do not write, only check md5 and meta
  if [ "$VERIFY_ONLY" -eq 1 ]; then
    local vmd5=2 vmeta=0
    vmd5=$(verify_md5_file "$d"); # 0 ok, 1 mismatch, 2 missing
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
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find_file_expr "$d" | LC_ALL=C sort -z)

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: Would process ${#files[@]} files in $d"
  else
    : > "$tmp_sum" || { record_error "Cannot write $tmp_sum"; return; }
    : > "$tmp_meta" || { record_error "Cannot write $tmp_meta"; return; }
  fi

  # Build old manifest maps and inode-based cache (for hardlinks)
  declare -A old_path_by_inode old_mtime old_size old_hash
  declare -A inode_hash_cache  # inode:dev -> hash
  for p in "${!meta_inode_dev[@]}"; do
    old_path_by_inode["${meta_inode_dev[$p]}"]="$p"
    old_mtime["$p"]="${meta_mtime[$p]}"
    old_size["$p"]="${meta_size[$p]}"
    old_hash["$p"]="${meta_hash_by_path[$p]}"
    inode_hash_cache["${meta_inode_dev[$p]}"]="${meta_hash_by_path[$p]}"
  done

  # Collect tasks for hashing
  local results_file=""
  if [ "$DRY_RUN" -eq 0 ]; then
    results_file="$(mktemp "${TMPDIR:-/tmp}/hash_results.XXXXXX")" || results_file="$tmp_sum.hash.results"
    : > "$results_file"
  fi

  declare -A path_to_hash  # path -> hash (filled for reused or after parallel)
  declare -A path_to_inode # path -> inode:dev
  declare -A path_to_meta  # path -> "fname<TAB>inode<TAB>dev<TAB>mtime<TAB>size"

  # Decide reuse vs compute; spawn parallel hash tasks
  for fpath in "${files[@]}"; do
    local fname inode dev mtime size inode_dev reuse h
    fname=$(basename "$fpath")
    inode=$(get_inode "$fpath"); dev=$(get_dev "$fpath")
    mtime=$(get_mtime "$fpath"); size=$(get_size "$fpath")
    inode_dev="${inode}:${dev}"
    reuse=0; h=""

    # Strong incremental by inode (renames and hardlinks)
    if [ -n "${inode_hash_cache[$inode_dev]:-}" ]; then
      if [ -n "${old_path_by_inode[$inode_dev]:-}" ]; then
        local oldp="${old_path_by_inode[$inode_dev]}"
        if [ "${old_mtime[$oldp]}" = "$mtime" ] && [ "${old_size[$oldp]}" = "$size" ]; then
          h="${inode_hash_cache[$inode_dev]}"; reuse=1
          log "Reusing hash via inode for $fname (inode=$inode_dev from $oldp)"
        fi
      fi
    fi

    # Fallback: reuse by same path if unchanged
    if [ "$reuse" -eq 0 ] && [ -n "${meta_mtime[$fname]:-}" ]; then
      if [ "${meta_mtime[$fname]}" = "$mtime" ] && [ "${meta_size[$fname]}" = "$size" ]; then
        h="${meta_hash_by_path[$fname]}"; reuse=1
        inode_hash_cache["$inode_dev"]="$h"
        log "Reusing hash for unchanged file $fname"
      fi
    fi

    path_to_inode["$fpath"]="$inode_dev"
    path_to_meta["$fpath"]="${fname}"$'\t'"${inode}"$'\t'"${dev}"$'\t'"${mtime}"$'\t'"${size}"

    if [ "$reuse" -eq 1 ]; then
      path_to_hash["$fpath"]="$h"
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRYRUN: would hash $fpath with $PER_FILE_ALGO"
      path_to_hash["$fpath"]=""
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
      path_to_hash["$rpath"]="$rhash"
      local id="${path_to_inode[$rpath]}"
      [ -n "$id" ] && [ -n "$rhash" ] && inode_hash_cache["$id"]="$rhash"
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
    for fpath in "${files[@]}"; do
      local fname h meta_line
      fname=$(basename "$fpath")
      h="${path_to_hash[$fpath]}"
      meta_line="${path_to_meta[$fpath]}"$'\t'"$h"
      printf '%s  %s\n' "$h" "$fname" >> "$tmp_sum"
      printf '%s\n' "$meta_line" >> "$tmp_meta"
    done

    local lockfile="${metaf}${LOCK_SUFFIX}"
    with_lock "$lockfile" write_meta "$metaf" "$(cat "$tmp_meta")"
    mv -f "$tmp_sum" "$sumf" || record_error "Failed to move $tmp_sum -> $sumf"
    log "Wrote $sumf and $metaf"
  fi

  log "Finished directory: $d"
  LOG_FILEPATH=""
}

process_directories() {
  local base="$1"
  cleanup_leftover_locks "$base"
  local -a all_dirs to_process skipped
  while IFS= read -r -d '' dd; do all_dirs+=("$dd"); done < <(find "$base" -type d -print0 | LC_ALL=C sort -z)

  for d in "${all_dirs[@]}"; do
    local base_name=$(basename "$d")
    case "$base_name" in .*) dbg "Skipping hidden $d"; skipped+=("$d"); continue ;; esac
    local sumf="$d/$MD5_FILENAME" metaf="$d/$META_FILENAME"

    # Verify-only mode: we process every directory (but without writes) in process_single_directory
    if [ "$VERIFY_ONLY" -eq 1 ]; then
      to_process+=("$d")
      continue
    fi

    if [ -f "$sumf" ] && [ "$FORCE_REBUILD" -eq 0 ]; then
      # If any file newer than sumfile, we need to process
      if find_file_expr "$d" | LC_ALL=C xargs -0 -n1 -I{} bash -c 'test "{}" -nt "'"$sumf"'" && printf "%s\n" "{}" && exit 0' 2>/dev/null | grep -q .; then
        dbg "Newer file detected in $d -> will process"; to_process+=("$d"); continue
      fi
      local fcount sumlines
      fcount=$(count_files "$d")
      sumlines=$(wc -l <"$sumf" 2>/dev/null || echo 0)
      if [ "$fcount" -ne "$sumlines" ]; then dbg "Count mismatch in $d -> will process"; to_process+=("$d"); continue; fi

      # Use meta to quickly determine unchanged directories
      if verify_meta_sig "$metaf"; then
        read_meta "$metaf"
        local changed=0
        for p in "${!meta_mtime[@]}"; do
          if [ ! -e "$d/$p" ]; then changed=1; break; fi
          if [ "$(get_mtime "$d/$p")" != "${meta_mtime[$p]}" ] || [ "$(get_size "$d/$p")" != "${meta_size[$p]}" ]; then changed=1; break; fi
        done
        if [ "$changed" -eq 0 ]; then
          log "Skipping $d (manifest indicates up-to-date)"
          count_skipped=$((count_skipped+1))
          skipped+=("$d")
          continue
        fi
      fi
      to_process+=("$d")
    else
      to_process+=("$d")
    fi
  done

  log "Directories to process: ${#to_process[@]}"
  for d in "${to_process[@]}"; do process_single_directory "$d"; done
}
