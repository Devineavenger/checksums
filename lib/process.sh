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
# process.sh
# shellcheck source=lib/init.sh
# shellcheck source=lib/logging.sh
# shellcheck source=lib/hash.sh
#
# Per-directory processing: hashing, meta writing, reuse heuristics, and verify-only mode.
# Preserves the original flow while adding parallel hashing and inode-based reuse.
#
# High-level overview:
# - Orchestrator selects directories; this module ensures each directory is handled safely.
# - For normal runs, we compute hashes, write an .md5 list, and a richer .meta with extra fields.
# - For verify-only runs, we parse existing manifests and report integrity without writing anything.
# - We minimize unnecessary side effects (like logs or manifests) in container-only or empty folders.
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
#  - Hashing is batched adaptively (based on file size), and parallel workers write results
#    to per-batch files to avoid contention and make aggregation deterministic.
#
# Backwards-compatibility:
#  - Behavior mirrors the previous monolithic checksums.sh while adding safety guards and
#    improved diagnostics to make race conditions and log mismatches easier to diagnose.
#  - Bash < 4 support: when associative arrays are not available, text-based "maps" are used
#    via helper functions (map_get/map_set) and temporary files, preserving functionality.


# Stub progress callbacks for test harnesses that source process.sh without orchestrator.sh.
# The real implementations live in orchestrator.sh and override these when loaded.
if ! declare -F _progress_file_done >/dev/null 2>&1; then
  _progress_file_done() { :; }
fi
if ! declare -F _progress_update >/dev/null 2>&1; then
  _progress_update() { :; }
fi

# Ensure associative meta arrays exist (no-op if already declared in init.sh).
# Works in shells that support -A and is safe if arrays are already declared.
# These hold previous-run metadata so we can reuse hashes based on inode/dev pairs or paths.
if declare -p -A >/dev/null 2>&1; then
  declare -gA meta_inode_dev meta_size meta_hash_by_path 2>/dev/null || true
  # initialize to empty maps only if not already associative arrays
  : "${meta_inode_dev:=}"  # no-op; keeps ShellCheck quiet about undefined vars
fi

# Precompute batch thresholds once per run to avoid repeated numfmt conversions.
# Ensure global associative type even inside functions.
# These thresholds let us choose batch sizes (how many files a worker processes) by file size,
# balancing throughput and resource use.
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

# Parse BATCH_RULES (e.g. "0-10M:20,10M-40M:20,>40M:5") into byte ranges and counts.
# Called once (orchestrator) to populate BATCH_THRESHOLDS or THRESHOLDS_LIST.
# Rules are forgiving to whitespace and validated to avoid malformed entries.
init_batch_thresholds() {
  local rules="${BATCH_RULES:-0-10M:20,10M-40M:20,>40M:5}"
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

      # Store open-ended as ">$high_bytes" so the classify_batch_size lookup's
      # ">"* case branch can match it. The previous format "$high_bytes-" matched
      # the "*-*" branch instead, where ${key##*-} is empty → rule was skipped.
      if declare -p -A >/dev/null 2>&1; then
        BATCH_THRESHOLDS[">$high_bytes"]="$count"
      else
        THRESHOLDS_LIST+="> $high_bytes $count"$'\n'
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
# The input is raw bytes (numeric only); non-digit chars are stripped for resilience.
# Returns an integer count for how many files to include per batch at this size.
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
  # Entry point for a single directory. Defensive, side-effect-aware, and consistent.
  if [ "${DEBUG:-0}" -gt 0 ]; then
    dbg "Effective BATCH_RULES=$BATCH_RULES PARALLEL_JOBS=$PARALLEL_JOBS DRY_RUN=$DRY_RUN"
  fi
  local d="$1"

  if [ ! -d "$d" ]; then
    record_error "PROC: requested to process missing directory: $d"
    return 1
  fi

  log "PROC: enter process_single_directory $d DRY_RUN=$DRY_RUN VERIFY_ONLY=$VERIFY_ONLY SKIP_EMPTY=${SKIP_EMPTY:-} NO_ROOT_SIDEFILES=${NO_ROOT_SIDEFILES:-}"

  # Unconditionally purge our meta lock for this directory (crash-safe).
  # This targets only our sidecar lock, not arbitrary *.lock files.
  : "${LOCK_SUFFIX:=.lock}"
  if [ -z "${LOCK_SUFFIX}" ]; then
    LOCK_SUFFIX=".lock"
  fi
  local sumf metaf logf
  sumf="$(_sidecar_path "$d" "$SUM_FILENAME")"
  metaf="$(_sidecar_path "$d" "$META_FILENAME")"
  logf="$(_sidecar_path "$d" "$LOG_FILENAME")"
  # Debug: emit exact lock paths we will attempt to remove (visible in run log)
  dbg "PROC: removing possible stale locks: ${sumf}${LOCK_SUFFIX} ${metaf}${LOCK_SUFFIX} ${logf}${LOCK_SUFFIX}"
  # Narrow, deterministic removal: only our sidecar locks in this directory.
  rm -f -- "${sumf}${LOCK_SUFFIX}" "${metaf}${LOCK_SUFFIX}" "${logf}${LOCK_SUFFIX}" 2>/dev/null || true

  if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ -n "${TARGET_DIR:-}" ]; then
    if [ "$(cd "$d" 2>/dev/null && pwd -P)" = "$(cd "${TARGET_DIR%/}" 2>/dev/null && pwd -P)" ]; then
      return 0
    fi
  fi

  local is_scheduled=0
  if [ "${USE_ASSOC:-0}" -eq 1 ]; then
    [ -n "${first_run_overwrite_set[$d]:-}" ] && is_scheduled=1
  else
    if [ -n "${MAP_first_run_overwrite:-}" ] && [ -f "$MAP_first_run_overwrite" ]; then
      if map_get "$MAP_first_run_overwrite" "$d" >/dev/null 2>&1; then is_scheduled=1; fi
    fi
  fi

  # Early decision: if SKIP_EMPTY applies and directory is not scheduled, use has_local_files
  # to avoid doing unnecessary work. This guard must not create side-effects.
  if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "${FORCE_REBUILD:-0}" -eq 0 ] && [ "${VERIFY_ONLY:-0}" -eq 0 ] && [ "$is_scheduled" -eq 0 ]; then
    if ! has_local_files "$d"; then
      return 0
    fi
  fi

  # Derive paths now (but do NOT create logs yet)
  sumf="$(_sidecar_path "$d" "$SUM_FILENAME")"
  metaf="$(_sidecar_path "$d" "$META_FILENAME")"
  logf="$(_sidecar_path "$d" "$LOG_FILENAME")"

  vlog "Starting directory: $d"
  dbg "sumfile: $sumf  metafile: $metaf  logfile: $logf"

  # Remove stale legacy lock if found (best-effort)
  if [ -f "${metaf}${LOCK_SUFFIX}" ]; then
    if [ ! -s "${metaf}${LOCK_SUFFIX}" ] || [ "$(find "${metaf}${LOCK_SUFFIX}" -mtime +0 -print 2>/dev/null)" ]; then
      dbg "Removing stale lock ${metaf}${LOCK_SUFFIX}"
      rm -f -- "${metaf}${LOCK_SUFFIX}" 2>/dev/null || dbg "Could not remove ${metaf}${LOCK_SUFFIX}"
    fi
  fi

  # Meta verification and possible removal
  if [ -f "$metaf" ] && ! verify_meta_sig "$metaf"; then
    record_error "Meta signature invalid for $metaf; ignoring meta and forcing rebuild"
    if [ "$VERIFY_ONLY" -eq 0 ]; then
      local lockfile="${metaf}${LOCK_SUFFIX}"
      with_lock "$lockfile" sh -c "rm -f -- \"\$1\"" sh "$metaf"
      [ -f "$metaf" ] && record_error "Could not remove invalid meta $metaf"
    fi
  fi

  # VERIFY_ONLY path (no writes)
  if [ "$VERIFY_ONLY" -eq 1 ]; then
    local vmd5
    # If there are no candidate files anywhere under this dir, treat as skipped.
    # If there are files but no MD5 manifest, record an error.
    if ! has_files "$d"; then
      log "${_C_CYAN}Verify-only:${_C_RST} skipped empty/container-only directory $d"
      vmd5=0
    elif [ -f "$sumf" ]; then
      emit_md5_file_details "$d" "$sumf"
      vmd5=$?
      emit_md5_detail "$d" "$vmd5"
    else
      # Only error when this directory actually contains files we care about.
      # Use has_local_files to detect files directly inside (container directories might
      # have descendents but no local files — those should be skipped, not error).
      if has_local_files "$d"; then
        vmd5=2
        record_error "Verify-only: MD5 file missing in $d"
      else
        log "${_C_CYAN}Verify-only:${_C_RST} no local files in $d and no MD5 present; skipping"
        vmd5=0
      fi
    fi

    if [ -f "$metaf" ]; then
      if verify_meta_sig "$metaf"; then
        log "${_C_CYAN}Verify-only:${_C_RST} ${_C_GREEN}META signature OK${_C_RST} for $d"
      else
        record_error "Verify-only: META signature invalid for $d"
      fi
    else
      log "${_C_CYAN}Verify-only:${_C_RST} ${_C_YELLOW}META file missing${_C_RST} in $d"
    fi

    count_verified=$((count_verified+1))
    log "Finished directory (verify-only): $d"
    LOG_FILEPATH=""
    return
  fi

  # Normal processing: read meta for reuse heuristics
  read_meta "$metaf"

  if [ -f "$metaf" ] && verify_meta_sig "$metaf"; then
    if [ "${SKIP_EMPTY:-1}" -eq 1 ] && has_files "$d"; then
      count_verified=$((count_verified+1))
      count_verified_existing=$((count_verified_existing+1))
    fi
  fi

  local tmp_sum="${sumf}.tmp" tmp_meta="${metaf}.tmp"
  local -a files=()
  # Collect candidate files now (this is authoritative list used for hashing)
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find_file_expr "$d" | LC_ALL=C sort -z)

  local total_files=${#files[@]}
  if [ "$total_files" -gt 100 ] && [ "${VERBOSE:-0}" -gt 0 ]; then
    vlog "PROC: $d has $total_files files; hashing will run with PARALLEL_JOBS=$PARALLEL_JOBS"
  fi

  # If there are no candidate files, return early before creating logs or other side-effects.
  if [ "$total_files" -eq 0 ]; then
    vlog "No candidate files in $d; skipping manifest creation"
    return 0
  fi

  # Only now create/rotate per-directory log because we will actually process this dir.
  # Minimal mode skips per-directory log creation entirely.
  LOG_FILEPATH=""
  if [ "$DRY_RUN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ] && [ "${MINIMAL:-0}" -eq 0 ]; then
    LOG_FILEPATH="$logf"
    dbg "PROC: LOG_FILEPATH set to $LOG_FILEPATH"
    rotate_log "$LOG_FILEPATH"
    : > "$LOG_FILEPATH"
    log_run_header "$LOG_FILEPATH"
  elif [ "$DRY_RUN" -eq 1 ]; then
    log "${_C_YELLOW}DRYRUN:${_C_RST} $total_files file(s) would be hashed in $d with $PER_FILE_ALGO (no changes made)"
  fi

  # Build old manifest maps and inode-based cache (for hardlinks).
  declare -A old_path_by_inode old_mtime old_size old_hash
  declare -A inode_hash_cache
  local MAP_old_path_by_inode MAP_old_mtime MAP_old_size MAP_old_hash MAP_inode_hash_cache
  if [ "${USE_ASSOC:-0}" -eq 0 ]; then
    MAP_old_path_by_inode="$(mktemp)"; : > "$MAP_old_path_by_inode"
    MAP_old_mtime="$(mktemp)"; : > "$MAP_old_mtime"
    MAP_old_size="$(mktemp)"; : > "$MAP_old_size"
    MAP_old_hash="$(mktemp)"; : > "$MAP_old_hash"
    MAP_inode_hash_cache="$(mktemp)"; : > "$MAP_inode_hash_cache"
  fi

  if [ "${USE_ASSOC:-0}" -eq 1 ]; then
    if [ "${#meta_inode_dev[@]}" -gt 0 ]; then
      for p in "${!meta_inode_dev[@]}"; do
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

  # Prepare hashing work
  local results_dir=""
  if [ "$DRY_RUN" -eq 0 ]; then
    results_dir="$(mktemp -d "${TMPDIR:-/tmp}/hash_results_dir.XXXXXX")" || results_dir="$tmp_sum.hash.results.d"
    mkdir -p -- "$results_dir"
  fi

  _proc_cleanup() {
    rm -f -- "${tmp_sum:-}" "${tmp_meta:-}" 2>/dev/null || true
    [ -n "${results_dir:-}" ] && rm -rf -- "${results_dir}" 2>/dev/null || true
  }

  declare -A path_to_hash path_to_inode path_to_meta
  local MAP_path_to_hash MAP_path_to_inode MAP_path_to_meta
  if [ "${USE_ASSOC:-0}" -eq 0 ]; then
    MAP_path_to_hash="$(mktemp)"; : > "$MAP_path_to_hash"
    MAP_path_to_inode="$(mktemp)"; : > "$MAP_path_to_inode"
    MAP_path_to_meta="$(mktemp)"; : > "$MAP_path_to_meta"
  fi

  local -a batch_files=()
  local batch_id=0
  local current_batch_size=0

  local no_reuse_val="${NO_REUSE:-0}"
  [ -z "$no_reuse_val" ] && no_reuse_val=0
  NO_REUSE="$no_reuse_val"

  declare -A _local_stat_cache=()
  for fpath in "${files[@]}"; do
    local fname inode dev mtime size inode_dev reuse h
    fname=${fpath##*/}
    local stat_line
    if [ -n "${_local_stat_cache[$fpath]:-}" ]; then
      stat_line=${_local_stat_cache[$fpath]}
    else
      stat_line=$(stat_all_fields "$fpath" 2>/dev/null | tr -d '\r' | head -n1) || stat_line=""
      _local_stat_cache["$fpath"]="$stat_line"
    fi
    IFS=$'\t' read -r inode dev mtime size <<<"$stat_line"
    inode=${inode:-0}; dev=${dev:-0}; mtime=${mtime:-0}; size=${size:-0}
    inode_dev="${inode}:${dev}"
    reuse=0; h=""

    if [ "${NO_REUSE:-0}" -eq 1 ]; then
      reuse=0
    else
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        if [ -n "${inode_hash_cache[$inode_dev]:-}" ] && [ -n "${old_path_by_inode[$inode_dev]:-}" ]; then
          local oldp="${old_path_by_inode[$inode_dev]}"
          if [ "${old_mtime[$oldp]}" = "$mtime" ] && [ "${old_size[$oldp]}" = "$size" ]; then
            h="${inode_hash_cache[$inode_dev]}"
            if [ -n "$h" ]; then
              reuse=1
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
          h="$cached"
          if [ -n "$h" ]; then
            reuse=1
            vlog "Reusing hash via inode for $fname (inode=$inode_dev from $oldp)"
          fi
        fi
      fi
    fi

    local no_reuse_val="${NO_REUSE:-0}"
    [ -z "$no_reuse_val" ] && no_reuse_val=0
    if (( ${reuse:-0} == 0 )) && (( ${no_reuse_val:-0} == 0 )); then
      dbg "DEBUG: considering reuse: reuse='${reuse:-0}' NO_REUSE='${no_reuse_val}' file='$fname'"
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        if [ -n "${meta_mtime[$fname]:-}" ] && [ "${meta_mtime[$fname]}" = "$mtime" ] && [ "${meta_size[$fname]}" = "$size" ]; then
          h="${meta_hash_by_path[$fname]:-}"
          if [ -n "$h" ]; then
            reuse=1
            inode_hash_cache["$inode_dev"]="$h"
            vlog "Reusing hash for unchanged file $fname"
          fi
        fi
      else
        local mm ms mh
        mm="$(map_get "$MAP_old_mtime" "$fname")"
        ms="$(map_get "$MAP_old_size" "$fname")"
        mh="$(map_get "$MAP_old_hash" "$fname")"
        if [ -n "$mm" ] && [ "$mm" = "$mtime" ] && [ -n "$ms" ] && [ "$ms" = "$size" ] && [ -n "$mh" ]; then
          h="$mh"
          if [ -n "$h" ]; then
            reuse=1
            map_set "$MAP_inode_hash_cache" "$inode_dev" "$h"
            vlog "Reusing hash for unchanged file $fname"
          fi
        fi
      fi
    fi

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
      _progress_file_done
      _progress_update
      continue
    fi

    if (( DRY_RUN == 1 )); then
      vlog "${_C_YELLOW}DRYRUN:${_C_RST} would hash $fpath with $PER_FILE_ALGO"
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        path_to_hash["$fpath"]=""
      else
        map_set "$MAP_path_to_hash" "$fpath" ""
      fi
      _progress_file_done
      _progress_update
    else
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

  # Flush any remaining files that did not fill the last batch threshold.
  # Without this, the last partial batch is never dispatched to a worker and
  # those files fall through to sequential file_hash() fallback calls, silently
  # defeating parallelism for every directory whose file count isn't an exact
  # multiple of the batch size (i.e. almost every directory).
  if (( DRY_RUN == 0 )) && [ "${#batch_files[@]}" -gt 0 ]; then
    _par_maybe_wait
    local worker_out="$results_dir/batch_${batch_id}.out"
    _do_hash_batch "$PER_FILE_ALGO" "$worker_out" "${batch_files[@]}" &
    HASH_PIDS+=("$!")
    HASH_PIDS_COUNT=${#HASH_PIDS[@]}
    batch_files=()
    batch_id=$((batch_id+1))
  fi

  if (( DRY_RUN == 0 )); then
    _par_wait_all
    for worker_out in "$results_dir"/*.out; do
      [ -f "$worker_out" ] || continue
      while IFS=$'\t' read -r rpath rhash; do
        if [ "${USE_ASSOC:-0}" -eq 1 ]; then
          path_to_hash["$rpath"]="${rhash:-}"
          local id="${path_to_inode[$rpath]:-}"
          [ -n "$id" ] && [ -n "${rhash:-}" ] && inode_hash_cache["$id"]="$rhash"
        else
          map_set "$MAP_path_to_hash" "$rpath" "${rhash:-}"
          local id; id="$(map_get "$MAP_path_to_inode" "$rpath")"
          [ -n "$id" ] && [ -n "${rhash:-}" ] && map_set "$MAP_inode_hash_cache" "$id" "$rhash"
        fi
        local bname; bname=$(basename "$rpath")
        if [ -n "${rhash:-}" ]; then
          vlog "Hashed $bname -> ${rhash:0:8}...${rhash: -8} (truncated)"
        else
          record_error "Hash failed for $rpath"
        fi
        _progress_file_done
        _progress_update
      done < "$worker_out"
      rm -f -- "$worker_out" 2>/dev/null || true
    done
    rmdir "$results_dir" 2>/dev/null || true
  fi

  if (( DRY_RUN == 0 )); then
    if [ "${USE_ASSOC:-0}" -eq 1 ]; then
      for fpath in "${files[@]}"; do
        local fname h meta_line
        fname=${fpath##*/}
        h="${path_to_hash[$fpath]:-}"
        if [ -z "$h" ]; then
          h="$(file_hash "$fpath" "$PER_FILE_ALGO")"
        fi
        printf '%s  ./%s\n' "$h" "$fname" >> "$tmp_sum"
        if [ "${MINIMAL:-0}" -eq 0 ]; then
          meta_line="${path_to_meta[$fpath]:-}"$'\t'"$h"
          printf '%s\n' "$meta_line" >> "$tmp_meta"
        fi
      done
    else
      for fpath in "${files[@]}"; do
        local fname h meta_line
        fname=${fpath##*/}
        h="$(map_get "$MAP_path_to_hash" "$fpath")"
        if [ -z "$h" ]; then
          h="$(file_hash "$fpath" "$PER_FILE_ALGO")"
        fi
        printf '%s  ./%s\n' "$h" "$fname" >> "$tmp_sum"
        if [ "${MINIMAL:-0}" -eq 0 ]; then
          meta_line="$(map_get "$MAP_path_to_meta" "$fpath")"$'\t'"${h:-}"
          printf '%s\n' "$meta_line" >> "$tmp_meta"
        fi
      done
      rm -f "$MAP_path_to_hash" "$MAP_path_to_inode" "$MAP_path_to_meta" 2>/dev/null || true
    fi

    if [ -s "$tmp_sum" ]; then
      if [ "${MINIMAL:-0}" -eq 0 ]; then
        local lockfile="${metaf}${LOCK_SUFFIX}"
        local -a meta_lines=()
        if [ -f "$tmp_meta" ]; then
          while IFS= read -r line; do
            meta_lines+=("$line")
          done < "$tmp_meta"
        fi
        with_lock "$lockfile" write_meta "$metaf" "${meta_lines[@]}"
        log "Wrote $sumf and $metaf"
      else
        log "Wrote $sumf"
      fi
      mv -f "$tmp_sum" "$sumf" || record_error "Failed to move $tmp_sum -> $sumf"
      count_created=$((count_created+1))
    else
      vlog "Skipped writing manifests for $d (no local files)"
      LOG_FILEPATH=""
      _proc_cleanup
      return 0
    fi

    local repaired=0
    local tmp_fixed="${sumf}.fixed"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local hash fname
      hash="${line%%[[:space:]]*}"
      fname="${line#"$hash"}"
      fname="$(printf '%s' "$fname" | sed -E 's/^[[:space:]]+[*[:space:]]*//')"
      if [ -z "$hash" ] || [[ "$hash" =~ ^[[:space:]]*$ ]]; then
        local fpath="$d/$fname"
        local newhash
        newhash="$(file_hash "$fpath" "$PER_FILE_ALGO")"
        printf '%s  ./%s\n' "$newhash" "$fname" >> "$tmp_fixed"
        repaired=1
      else
        printf '%s\n' "$line" >> "$tmp_fixed"
      fi
    done < "$sumf"
    if [ "$repaired" -eq 1 ]; then
      mv -f "$tmp_fixed" "$sumf"
      log "Repaired malformed entries in $sumf"
    else
      rm -f "$tmp_fixed" 2>/dev/null || true
    fi
  fi

  if [ "${USE_ASSOC:-0}" -eq 0 ]; then
    rm -f "$MAP_old_path_by_inode" "$MAP_old_mtime" "$MAP_old_size" "$MAP_old_hash" "$MAP_inode_hash_cache" 2>/dev/null || true
  fi

  # Clear stat cache to prevent unbounded memory growth across directories
  if [ "${USE_ASSOC:-0}" -eq 1 ]; then
    STAT_CACHE=()
  fi

  log "Finished directory: $d"
  _proc_cleanup
  LOG_FILEPATH=""
}

# Note: decide_directories_plan intentionally lives in lib/planner.sh