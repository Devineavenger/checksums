#!/usr/bin/env bash
# shellcheck disable=SC2034
# process.sh
# shellcheck source=lib/init.sh
# shellcheck source=lib/logging.sh
# shellcheck source=lib/hash.sh
#
# Per-directory processing: hashing, meta writing, reuse heuristics, and verify-only mode.
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
#
# Responsibilities:
#  - Respect SKIP_EMPTY and NO_ROOT_SIDEFILES policies to avoid creating sidecar files
#    in directories that should remain untouched (root or empty/container-only dirs).
#  - Provide a defensive entry point so callers (orchestrator) can safely invoke the
#    processor even when race conditions might remove directories between planning and execution.
#  - Prepare per-directory log files (rotation + header), compute or reuse per-file hashes,
#    write atomic manifests (.md5 and .meta) with signatures and run/audit trail, and collect
#    per-run error counters and diagnostics.
#
# Design notes and rationale:
#  - The function returns early without side effects when SKIP_EMPTY indicates the directory
#    should be skipped; this prevents creating any .meta/.md5/.log files unnecessarily.
#  - We expose LOG_FILEPATH as the current logfile so logging helpers write to the correct per-dir log.
#  - Reuse heuristics use inode-aware caching to handle renames and hardlinks, and fall back to
#    path-based reuse when associative arrays are not available.
#  - All temporary artifacts are used in the local scope and cleaned up where appropriate.
#
# Backwards-compatibility:
#  - Behavior mirrors the previous monolithic checksums.sh while adding safety guards and
#    improved diagnostics to make race conditions and log mismatches easier to diagnose.

# Ensure associative meta arrays exist (no-op if already declared in init.sh).
# Works in shells that support -A and is safe if arrays are already declared.
if declare -p -A >/dev/null 2>&1; then
  declare -gA meta_inode_dev meta_size meta_hash_by_path 2>/dev/null || true
  # initialize to empty maps only if not already associative arrays
  : "${meta_inode_dev:=}"  # no-op; keeps ShellCheck quiet about undefined vars
fi

# Ensure parallel job arrays exist to avoid unbound var warnings
# Remove unused local arrays (pids/pids_count). Worker control uses HASH_PIDS/HASH_PIDS_COUNT in hash.sh.
# This avoids confusion and keeps state centralized in hash helpers.
# (no replacement needed)

# Precompute batch thresholds once per run to avoid repeated numfmt conversions.
# Ensure global associative type even inside functions.
if declare -p -A >/dev/null 2>&1; then
  # re-declare globally to avoid local shadowing issues under set -u
  declare -gA BATCH_THRESHOLDS 2>/dev/null || true
  # If not yet declared as associative, reset and declare
  if ! declare -p BATCH_THRESHOLDS 2>/dev/null | grep -q 'declare \-A'; then
    unset BATCH_THRESHOLDS
    declare -gA BATCH_THRESHOLDS
  fi
else
  # Fallback (Bash < 4): keep a scalar to avoid set -u complaints; not used on Bash 5.x
  BATCH_THRESHOLDS=()
fi
# Fallback list is referenced below; declare defensively even on Bash 5.x
declare -g THRESHOLDS_LIST=""

# Parse BATCH_RULES (e.g. "0-1M:20,1M-80M:5,>80M:1") into byte ranges and counts.
# Called once (orchestrator) to populate BATCH_THRESHOLDS or THRESHOLDS_LIST.
init_batch_thresholds() {
  local rules="${BATCH_RULES:-0-1M:20,1M-80M:5,>80M:1}"
  IFS=',' read -ra parts <<< "$rules"

  for rule in "${parts[@]}"; do
    # trim all whitespace using Bash built-ins
    rule="${rule//[[:space:]]/}"

    if [[ "$rule" == *-*:* ]]; then
      # Fixed range: LOW-HIGH:COUNT
      local range count low high low_bytes high_bytes
      range="${rule%%:*}"
      count="${rule##*:}"
      low="${range%%-*}"
      high="${range##*-}"

      dbg "rule=$rule range=$range low=$low high=$high count=$count"

      case "$count" in ''|*[!0-9]*) dbg "init_batch_thresholds: invalid count='$count' in rule='$rule'"; continue ;; esac

      low_bytes="$(_to_bytes "$low")"
      high_bytes="$(_to_bytes "$high")"

      case "$low_bytes"  in ''|*[!0-9]*) dbg "init_batch_thresholds: low not numeric for '$rule'"; continue ;; esac
      case "$high_bytes" in ''|*[!0-9]*) dbg "init_batch_thresholds: high not numeric for '$rule'"; continue ;; esac

      if declare -p -A >/dev/null 2>&1; then
        BATCH_THRESHOLDS["$low_bytes-$high_bytes"]="$count"
      else
        THRESHOLDS_LIST+="$low_bytes $high_bytes $count"$'\n'
      fi

    elif [[ "${rule:0:1}" == ">" && "$rule" == *:* ]]; then
      # Open-ended: >HIGH:COUNT
      local high count high_bytes
      high="${rule#*>}"
      count="${high##*:}"
      high="${high%%:*}"

      dbg "rule=$rule high=$high count=$count"

      case "$count" in ''|*[!0-9]*) dbg "init_batch_thresholds: invalid count='$count' in rule='$rule'"; continue ;; esac

      high_bytes="$(_to_bytes "$high")"
      case "$high_bytes" in ''|*[!0-9]*) dbg "init_batch_thresholds: high not numeric for '$rule'"; continue ;; esac

      # Store open-ended as "<high_bytes>-"
      if declare -p -A >/dev/null 2>&1; then
        BATCH_THRESHOLDS["$high_bytes-"]="$count"
      else
        THRESHOLDS_LIST+="$high_bytes- $count"$'\n'
      fi

    else
      dbg "init_batch_thresholds: unrecognized rule format: '$rule'"
    fi
  done

  # Optional debug print
  if [ "${DEBUG:-0}" -gt 0 ]; then
    if declare -p -A >/dev/null 2>&1; then
      dbg "BATCH_THRESHOLDS contents (sorted):"
      for k in $(printf '%s\n' "${!BATCH_THRESHOLDS[@]}" | sort -V); do
        dbg "  $k -> ${BATCH_THRESHOLDS[$k]}"
      done
    else
      dbg "THRESHOLDS_LIST:"
      dbg "$(printf '%s' "$THRESHOLDS_LIST")"
    fi
  fi
}


# Lookup batch size based on precomputed thresholds (default=1).
classify_batch_size() {
  # Expect byte-sized integer input; defend against empty/non-digit inputs.
  local size_raw="${1:-0}"
  # keep only digits; empty -> 0
  local size
  size="$(printf '%s' "$size_raw" | sed -E 's/[^0-9]//g')"
  [ -z "$size" ] && size=0

  if declare -p -A >/dev/null 2>&1; then
    for key in "${!BATCH_THRESHOLDS[@]}"; do
      case "$key" in
        *-*)
          local low="${key%%-*}" high="${key##*-}"
          # skip malformed thresholds
          [[ -z "$low" || -z "$high" || "$low" =~ [^0-9] || "$high" =~ [^0-9] ]] && continue
          if (( size >= low )) && (( size < high )); then
            echo "${BATCH_THRESHOLDS[$key]}"; return
          fi
          ;;
        ">"*)
          local high="${key#*>}"
          [[ -z "$high" || "$high" =~ [^0-9] ]] && continue
          if (( size >= high )); then
            echo "${BATCH_THRESHOLDS[$key]}"; return
          fi
          ;;
      esac
    done
  else
    # fallback: parse THRESHOLDS_LIST safely
    local line low high count
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in
        "> "*)
          read -r _ high count <<<"$line"
          [[ -z "$high" || -z "$count" || "$high" =~ [^0-9] || "$count" =~ [^0-9] ]] && continue
          if (( size >= high )); then echo "$count"; return; fi
          ;;
        *)
          read -r low high count <<<"$line"
          [[ -z "$low" || -z "$high" || -z "$count" || "$low" =~ [^0-9] || "$high" =~ [^0-9] || "$count" =~ [^0-9] ]] && continue
          if (( size >= low )) && (( size < high )); then echo "$count"; return; fi
          ;;
      esac
    done <<<"$THRESHOLDS_LIST"
  fi
  echo 1
}

process_single_directory() {
  if [ "${DEBUG:-0}" -gt 0 ]; then
    dbg "Effective BATCH_RULES=$BATCH_RULES PARALLEL_JOBS=$PARALLEL_JOBS DRY_RUN=$DRY_RUN"
  fi
  local d="$1"

  # Defensive check: if caller passed a non-existent path, bail out cleanly.
  # This prevents the processor from creating logs or manifests for missing dirs
  # when the orchestrator's plan becomes stale (e.g., race with external removal).
  if [ ! -d "$d" ]; then
    record_error "PROC: requested to process missing directory: $d"
    return 1
  fi

  log "PROC: enter process_single_directory $d DRY_RUN=$DRY_RUN VERIFY_ONLY=$VERIFY_ONLY SKIP_EMPTY=${SKIP_EMPTY:-} NO_ROOT_SIDEFILES=${NO_ROOT_SIDEFILES:-}"

  # Absolute root guard: if NO_ROOT_SIDEFILES=1 and d is the run TARGET_DIR, do nothing.
  # This preserves the invariant that the run root remains free of sidecar files unless
  # the operator explicitly opts in via --allow-root-sidefiles (NO_ROOT_SIDEFILES=0).
  if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ -n "${TARGET_DIR:-}" ]; then
    # Compare canonical absolute paths to avoid trailing-slash or symlink mismatches
    if [ "$(cd "$d" 2>/dev/null && pwd -P)" = "$(cd "${TARGET_DIR%/}" 2>/dev/null && pwd -P)" ]; then
      return 0
    fi
  fi

  # If this directory is explicitly scheduled by first-run, do not let SKIP_EMPTY skip it.
  local is_scheduled=0
  if [ "${USE_ASSOC:-0}" -eq 1 ]; then
    [ -n "${first_run_overwrite_set[$d]:-}" ] && is_scheduled=1
  else
    if [ -n "${MAP_first_run_overwrite:-}" ] && [ -f "$MAP_first_run_overwrite" ]; then
      if map_get "$MAP_first_run_overwrite" "$d" >/dev/null 2>&1; then is_scheduled=1; fi
    fi
  fi

  # Absolute early guard: skip if SKIP_EMPTY and no regular files anywhere under d.
  # This must happen before any filename derivation, logging to per-dir logs, or side effects.
  if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "${FORCE_REBUILD:-0}" -eq 0 ] && [ "${VERIFY_ONLY:-0}" -eq 0 ] && [ "$is_scheduled" -eq 0 ]; then
    # Skip processing if there are no regular files directly inside this directory.
    if ! has_local_files "$d"; then
      return 0
    fi
  fi

  # Only derive filenames after we know the dir should be processed
  local sumf="$d/$MD5_FILENAME" metaf="$d/$META_FILENAME" logf="$d/$LOG_FILENAME"

  # Prepare per-directory log: rotate and add audit run header.
  # Setting LOG_FILEPATH ensures subsequent log() calls append to the per-dir logfile.
  LOG_FILEPATH="$logf"
  log "PROC: LOG_FILEPATH set to $LOG_FILEPATH"
  if [ "$DRY_RUN" -eq 0 ]; then
    rotate_log "$LOG_FILEPATH"
    : > "$LOG_FILEPATH"
    log_run_header "$LOG_FILEPATH"
  fi

  log "Starting directory: $d"
  log "sumfile: $sumf  metafile: $metaf  logfile: $logf"

  # remove stale legacy lock if found (best-effort)
  if [ -f "${metaf}${LOCK_SUFFIX}" ]; then
    if [ ! -s "${metaf}${LOCK_SUFFIX}" ] || [ "$(find "${metaf}${LOCK_SUFFIX}" -mtime +0 -print 2>/dev/null)" ]; then
      dbg "Removing stale lock ${metaf}${LOCK_SUFFIX}"
      rm -f -- "${metaf}${LOCK_SUFFIX}" 2>/dev/null || dbg "Could not remove ${metaf}${LOCK_SUFFIX}"
    fi
  fi

  # If meta exists, verify signature; otherwise ignore/force rebuild.
  # Invalid signatures are treated as if the meta is absent: we force rebuild.
  if [ -f "$metaf" ] && ! verify_meta_sig "$metaf"; then
    record_error "Meta signature invalid for $metaf; ignoring meta and forcing rebuild"
    # In verify-only mode, we don't delete or rewrite; just record error and continue
    if [ "$VERIFY_ONLY" -eq 0 ]; then
      # Acquire the same lock before removing the invalid meta to avoid races with other runs
      # that might attempt to write while we delete (TOCTOU protection).
      local lockfile="${metaf}${LOCK_SUFFIX}"
      # Use double quotes and $1 to refer to the metaf argument passed to sh -c
      with_lock "$lockfile" sh -c "rm -f -- \"\$1\"" sh "$metaf"
      [ -f "$metaf" ] && record_error "Could not remove invalid meta $metaf"
    fi
  fi

  # Verification-only mode: do not write; only check md5 and meta.
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

  # If meta signature verified and unchanged, count as verified too
  if [ -f "$metaf" ] && verify_meta_sig "$metaf"; then
    if [ "${SKIP_EMPTY:-1}" -eq 1 ] && has_files "$d"; then
      count_verified=$((count_verified+1))
    fi
  fi

  local tmp_sum="${sumf}.tmp" tmp_meta="${metaf}.tmp"
  local -a files=()
  # Collect candidate files (NUL-delimited), sort for stable order
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find_file_expr "$d" | LC_ALL=C sort -z)

  # Progress hint for large directories (only when verbose or many files)
  local total_files=${#files[@]}
  if [ "$total_files" -gt 100 ] && [ "${VERBOSE:-0}" -gt 0 ]; then
    vlog "PROC: $d has $total_files files; hashing will run with PARALLEL_JOBS=$PARALLEL_JOBS"
  fi

  # Build old manifest maps and inode-based cache (for hardlinks)
  # dual approach depending on USE_ASSOC.
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
    # meta_* arrays are populated by read_meta in lib/meta.sh
    if [ "${#meta_inode_dev[@]}" -gt 0 ]; then
      for p in "${!meta_inode_dev[@]}"; do
        # guard against unset keys under set -u
        if [ -n "${meta_inode_dev[$p]:-}" ]; then
          old_path_by_inode["${meta_inode_dev[$p]}"]="$p"
          old_mtime["$p"]="${meta_mtime[$p]:-}"
          old_size["$p"]="${meta_size[$p]:-}"
          old_hash["$p"]="${meta_hash_by_path[$p]:-}"
          inode_hash_cache["${meta_inode_dev[$p]}"]="${meta_hash_by_path[$p]:-}"
        fi
      done
    fi
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
  local results_dir=""
  if [ "$DRY_RUN" -eq 0 ]; then
    results_dir="$(mktemp -d "${TMPDIR:-/tmp}/hash_results_dir.XXXXXX")" || results_dir="$tmp_sum.hash.results.d"
    # Ensure directory exists even if mktemp fallback path is used
    mkdir -p -- "$results_dir"
  fi
  # Ensure temporary artifacts are cleaned up deterministically.
  # Avoid trapping RETURN globally; instead perform explicit cleanup at each exit point.
  _proc_cleanup() {
    rm -f -- "${tmp_sum:-}" "${tmp_meta:-}" "${results_file:-}" 2>/dev/null || true
  }

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

  # Batch state
  local -a batch_files=()
  local batch_id=0
  local current_batch_size=0

  # Normalize NO_REUSE once to avoid repeated empty checks
  local no_reuse_val="${NO_REUSE:-0}"
  [ -z "$no_reuse_val" ] && no_reuse_val=0
  NO_REUSE="$no_reuse_val"

  # Decide reuse vs compute; spawn parallel hash tasks
  # Local per-directory stat cache to avoid repeated stat calls within this pass.
  declare -A _local_stat_cache=()
  for fpath in "${files[@]}"; do
    local fname inode dev mtime size inode_dev reuse h
    # Faster than basename: use parameter expansion (no external process).
    fname=${fpath##*/}
    # Use a single stat invocation to fetch inode/dev/mtime/size to reduce overhead.
    # Parse stat_all_fields output without forking awk 4x; use shell IFS read instead.
    local stat_line
    if [ -n "${_local_stat_cache[$fpath]:-}" ]; then
      stat_line=${_local_stat_cache[$fpath]}
    else
      stat_line=$(stat_all_fields "$fpath" 2>/dev/null | tr -d '\r' | head -n1) || stat_line=""
      _local_stat_cache["$fpath"]="$stat_line"
    fi
    # Split TAB-separated fields into variables in one builtin call (no external forks).
    IFS=$'\t' read -r inode dev mtime size <<<"$stat_line"
    inode=${inode:-0}; dev=${dev:-0}; mtime=${mtime:-0}; size=${size:-0}
    inode_dev="${inode}:${dev}"
    reuse=0; h=""

    # If NO_REUSE=1, skip all reuse heuristics and force recomputation
    if [ "${NO_REUSE:-0}" -eq 1 ]; then
      reuse=0
    else
      # Strong incremental by inode (renames and hardlinks)
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        if [ -n "${inode_hash_cache[$inode_dev]:-}" ]; then
          if [ -n "${old_path_by_inode[$inode_dev]:-}" ]; then
            local oldp="${old_path_by_inode[$inode_dev]}"
            if [ "${old_mtime[$oldp]}" = "$mtime" ] && [ "${old_size[$oldp]}" = "$size" ]; then
              h="${inode_hash_cache[$inode_dev]}"; reuse=1
              vlog "Reusing hash via inode for $fname (inode=$inode_dev from $oldp)"
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
          vlog "Reusing hash via inode for $fname (inode=$inode_dev from $oldp)"
        fi
      fi
	fi

    # Fallback: reuse by same path if unchanged (disabled when NO_REUSE=1)
    # Use arithmetic context to avoid [: : integer expected] on empty operands
    local no_reuse_val="${NO_REUSE:-0}"
    [ -z "$no_reuse_val" ] && no_reuse_val=0
    if (( ${reuse:-0} == 0 )) && (( ${no_reuse_val:-0} == 0 )); then
      dbg "DEBUG: considering reuse: reuse='${reuse:-0}' NO_REUSE='${no_reuse_val}' file='$fname'"
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        if [ -n "${meta_mtime[$fname]:-}" ] && [ "${meta_mtime[$fname]}" = "$mtime" ] && [ "${meta_size[$fname]}" = "$size" ]; then
          h="${meta_hash_by_path[$fname]}"; reuse=1
          inode_hash_cache["$inode_dev"]="$h"
          vlog "Reusing hash for unchanged file $fname"
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
          vlog "Reusing hash for unchanged file $fname"
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

    if (( reuse == 1 )); then
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        path_to_hash["$fpath"]="$h"
      else
        map_set "$MAP_path_to_hash" "$fpath" "$h"
      fi
      continue
    fi

    if (( DRY_RUN == 1 )); then
      log "DRYRUN: would hash $fpath with $PER_FILE_ALGO"
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        path_to_hash["$fpath"]=""
      else
        map_set "$MAP_path_to_hash" "$fpath" ""
      fi
    else
      # Adaptive batching: decide batch size based on file size
      local batch_size; batch_size=$(classify_batch_size "$size")
      batch_files+=("$fpath")
      current_batch_size=$((current_batch_size+1))
      if (( current_batch_size >= batch_size )); then
        _par_maybe_wait
        local worker_out="$results_dir/batch_${batch_id}.out"
        _do_hash_batch "$PER_FILE_ALGO" "$worker_out" "${batch_files[@]}" &
        HASH_PIDS+=("$!")
        HASH_PIDS_COUNT=${#HASH_PIDS[@]}
        batch_files=()
        current_batch_size=0
        batch_id=$((batch_id+1))
      fi
    fi
  done

  # Legacy xargs block removed; rely on existing _do_hash_batch + _par_wait_all
  # Collect hashed results from per-worker output files below.

  # Collect parallel results from per-worker output files (set -u safe)
  if (( DRY_RUN == 0 )); then
    _par_wait_all
    for worker_out in "$results_dir"/*.out; do
      [ -f "$worker_out" ] || continue
      while IFS=$'\t' read -r rpath rhash; do
        # Update path_to_hash and inode cache safely
        if [ "${USE_ASSOC:-0}" -eq 1 ]; then
          path_to_hash["$rpath"]="${rhash:-}"
          local id="${path_to_inode[$rpath]:-}"
          [ -n "$id" ] && [ -n "${rhash:-}" ] && inode_hash_cache["$id"]="$rhash"
        else
          map_set "$MAP_path_to_hash" "$rpath" "${rhash:-}"
          local id; id="$(map_get "$MAP_path_to_inode" "$rpath")"
          [ -n "$id" ] && [ -n "${rhash:-}" ] && map_set "$MAP_inode_hash_cache" "$id" "$rhash"
        fi
        # Optional: verbose hint
        local bname; bname=$(basename "$rpath")
        if [ -n "${rhash:-}" ]; then
          vlog "Hashed $bname -> ${rhash:0:8}...${rhash: -8} (truncated)"
        else
          record_error "Hash failed for $rpath"
        fi
      done < "$worker_out"
      rm -f -- "$worker_out" 2>/dev/null || true
    done
    rmdir "$results_dir" 2>/dev/null || true
  fi

  # Write outputs
  if (( DRY_RUN == 0 )); then
    if [ "${USE_ASSOC:-0}" -eq 1 ]; then
      for fpath in "${files[@]}"; do
        local fname h meta_line
        fname=${fpath##*/}
        h="${path_to_hash[$fpath]:-}"
        meta_line="${path_to_meta[$fpath]:-}"$'\t'"$h"
        # Write filename with leading ./ to match standard md5sum format
        printf '%s  ./%s\n' "$h" "$fname" >> "$tmp_sum"
        printf '%s\n' "$meta_line" >> "$tmp_meta"
      done
    else
      for fpath in "${files[@]}"; do
        local fname h meta_line
        fname=${fpath##*/}
        h="$(map_get "$MAP_path_to_hash" "$fpath")"
        meta_line="$(map_get "$MAP_path_to_meta" "$fpath")"$'\t'"${h:-}"
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
  # deterministic cleanup of per-directory temporaries
  _proc_cleanup
  LOG_FILEPATH=""
}

# Note: decide_directories_plan intentionally lives in lib/planner.sh
# MFz