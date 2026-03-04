#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# planner.sh
# shellcheck source=lib/init.sh
# shellcheck source=lib/meta.sh
# shellcheck source=lib/stat.sh
# shellcheck source=lib/fs.sh
#
# Planning functions: quick preview and full accurate planning.
# Extracted from checksums.sh v2.12.5.
#
# ---------------------------------------------------------------------
# Quick preview planner
# Very fast, minimal I/O: enumerates directories, skips hidden ones,
# but avoids heavy checks (no meta verification, no stat loops).
# Used to present an immediate preview to the user before confirmation.
# ---------------------------------------------------------------------

decide_quick_plan() {
  local base="$1" out_proc="$2" out_skipped="$3"
  : > "$out_proc"
  : > "$out_skipped"

  while IFS= read -r -d '' d; do
    local bn
    bn=$(basename "$d")
    # Hidden folders are considered skipped for preview
    case "$bn" in
      .*) printf '%s\0' "$d" >> "$out_skipped"; continue ;;
    esac

    # When NO_ROOT_SIDEFILES is set, do not include the base directory in preview-to-process
    if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ "$d" = "$base" ]; then
      printf '%s\0' "$d" >> "$out_skipped"
      continue
    fi

    # Preview carve-out mirroring first-run: show md5-only dirs as 'to process'
    if [ "${FIRST_RUN:-0}" -eq 1 ] && [ -f "$d/$MD5_FILENAME" ] \
       && { [ ! -f "$d/$META_FILENAME" ] || [ ! -f "$d/$LOG_FILENAME" ]; }; then
      printf '%s\0' "$d" >> "$out_proc"; continue
    fi

    # Align preview with SKIP_EMPTY + local-file semantics
    if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "${FORCE_REBUILD:-0}" -eq 0 ] && [ "${VERIFY_ONLY:-0}" -eq 0 ]; then
      # If no files anywhere under d, skip entirely
      if ! has_files "$d"; then
        printf '%s\0' "$d" >> "$out_skipped"
        continue
      fi
      # If d contains no regular files directly (only files in subdirs), skip creating sidecars for d
      if ! has_local_files "$d"; then
        printf '%s\0' "$d" >> "$out_skipped"
        continue
      fi
    fi

    # For quick preview we classify everything else as to_process
    printf '%s\0' "$d" >> "$out_proc"
  done < <(find "$base" -type d -print0 | LC_ALL=C sort -z)
}

# ---------------------------------------------------------------------
# Full planner (side-effect-free): accurate decisions, may be slow.
# Builds NUL-delimited lists of to-process and skipped directories.
# ---------------------------------------------------------------------

decide_directories_plan() {
  local base="$1"
  local plan_to_process_file="$2"
  local plan_skipped_file="$3"
  # Optional: when VERIFY_MD5_DETAILS=1, run md5 verification on .md5-only dirs
  VERIFY_MD5_DETAILS="${VERIFY_MD5_DETAILS:-0}"

  : > "$plan_to_process_file"
  : > "$plan_skipped_file"

  # Collect all directories into an array first (needed for parallel dispatch)
  local -a _plan_dirs=()
  while IFS= read -r -d '' d; do
    _plan_dirs+=("$d")
  done < <(find "$base" -type d -print0 | LC_ALL=C sort -z)

  if [ "${PARALLEL_JOBS:-1}" -gt 1 ] && [ "${#_plan_dirs[@]}" -gt 1 ]; then
    _plan_parallel "$plan_to_process_file" "$plan_skipped_file"
  else
    _plan_sequential "$plan_to_process_file" "$plan_skipped_file"
  fi
}

# Plan a single directory: decide process vs skip.
# Uses plan_to_process_file and plan_skipped_file from caller scope.
_plan_one_directory() {
  local d="$1"

  local base_name sumf metaf reason changed
  base_name=$(basename "$d")
  sumf="$d/$MD5_FILENAME"
  if [ "${DEBUG:-0}" -gt 0 ]; then
    if [ -f "$sumf" ]; then
      dbg "sumfile present for $d -> $sumf"
    else
      dbg "sumfile missing for $d -> $sumf"
    fi
  fi
  metaf="$d/$META_FILENAME"
  reason="unknown"
  changed=1

  # Skip hidden folders
  case "$base_name" in
    .*) reason="hidden"; printf '%s\0' "$d" >> "$plan_skipped_file"; vlog "PLAN: skip $d reason=$reason"; return ;;
  esac

  # When NO_ROOT_SIDEFILES is set, never schedule the base directory itself
  if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ "$d" = "$base" ]; then
    reason="root-protected"
    printf '%s\0' "$d" >> "$plan_skipped_file"
    vlog "PLAN: skip $d reason=$reason"
    return
  fi

  # In verify-only, treat as processed (execution will avoid writes)
  if [ "$VERIFY_ONLY" -eq 1 ]; then
    reason="verify-only"
    printf '%s\0' "$d" >> "$plan_to_process_file"
    vlog "PLAN: process $d reason=$reason"
    return
  fi

  # First-run carve-out: If we are in FIRST_RUN and the directory has .md5
  # but is missing .meta or .log, schedule processing even if no user files exist.
  if [ "${FIRST_RUN:-0}" -eq 1 ]; then
    if [ -f "$sumf" ] \
       && { [ ! -f "$metaf" ] || [ ! -f "$d/$LOG_FILENAME" ]; } \
       && has_local_files "$d"; then
      reason="first-run-md5-only"
      printf '%s\0' "$d" >> "$plan_to_process_file"
      vlog "PLAN: process $d reason=$reason"
      return
    fi
  fi

  # Always skip directories with no user files when SKIP_EMPTY=1
  if [ "${SKIP_EMPTY:-1}" -eq 1 ] && ! has_files "$d"; then
    reason="no-user-files"
    printf '%s\0' "$d" >> "$plan_skipped_file"
    vlog "PLAN: skip $d reason=$reason"
    return
  fi

  if [ -f "$sumf" ] && [ "$FORCE_REBUILD" -eq 0 ]; then
    if find "$d" -maxdepth 1 -type f \
         ! -name "$MD5_EXCL" \
         ! -name "$META_EXCL" \
         ! -name "$LOG_EXCL" \
         ! -name "$LOCK_EXCL" \
         ! -name "$RUN_EXCL" \
         ! -name "$FIRST_RUN_EXCL" \
         ! -name "${ALT_LOG_EXCL}.log" \
         ! -name "${ALT_LOG_EXCL}.*.log" \
         -newer "$sumf" -print -quit 2>/dev/null | grep -q .; then
      reason="newer-file-detected"
      printf '%s\0' "$d" >> "$plan_to_process_file"
      vlog "PLAN: process $d reason=$reason"
      local md5_details="${VERIFY_MD5_DETAILS:-1}"
      if [ "$md5_details" -eq 1 ] && [ -f "$sumf" ]; then
        local vr
        vr=$(emit_md5_file_details "$d" "$sumf"; printf '%s' "$?")
        emit_md5_detail "$d" "$vr"
      fi
      return
    fi

    local fcount sumlines
    fcount=$(count_files "$d")
    sumlines=$(wc -l <"$sumf" 2>/dev/null || echo 0)
    if [ "$fcount" -ne "$sumlines" ]; then
      reason="filecount-mismatch"
      printf '%s\0' "$d" >> "$plan_to_process_file"
      vlog "PLAN: process $d reason=$reason"
      if [ "${VERIFY_MD5_DETAILS:-1}" -eq 1 ] && [ -f "$sumf" ]; then
        local vr
        vr=$(emit_md5_file_details "$d" "$sumf"; printf '%s' "$?")
        emit_md5_detail "$d" "$vr"
      fi
      return
    fi

    if [ -f "$metaf" ] && verify_meta_sig "$metaf"; then
      read_meta "$metaf"
      changed=0
      reason="meta-verified"
      local md5_details="${VERIFY_MD5_DETAILS:-1}"
      if [ "$md5_details" -eq 1 ] && [ -f "$sumf" ]; then
        local vr
        vr=$(emit_md5_file_details "$d" "$sumf"; printf '%s' "$?")
        emit_md5_detail "$d" "$vr"
      fi
      if [ "${USE_ASSOC:-0}" -eq 1 ]; then
        # shellcheck disable=SC2154  # meta_mtime/meta_size/meta_inode_dev defined in init.sh and populated by read_meta
        if [ "${#meta_mtime[@]}" -gt 0 ]; then
          for p in "${!meta_mtime[@]}"; do
            if [ ! -e "$d/$p" ]; then changed=1; reason="meta-missing-path"; break; fi
            local _sl
            _sl="$(stat_all_fields "$d/$p" 2>/dev/null)" || _sl=""
            local _si _sd _sm _ss
            IFS=$'\t' read -r _si _sd _sm _ss <<< "$_sl"
            if [ "${_sm:-0}" != "${meta_mtime[$p]:-}" ] \
               || [ "${_ss:-0}" != "${meta_size[$p]:-}" ] \
               || [ "${_si:-0}:${_sd:-0}" != "${meta_inode_dev[$p]:-}" ]; then
              changed=1; reason="meta-stat-changed"; break
            fi
          done
        fi
      else
        while IFS=$'\t' read -r path _inode _dev mtime size _hash; do
          [ -z "$path" ] && continue
          case "$path" in \#meta|\#sig|\#run) continue ;; esac
          if [ ! -e "$d/$path" ]; then changed=1; reason="meta-missing-path"; break; fi
          local _sl
          _sl="$(stat_all_fields "$d/$path" 2>/dev/null)" || _sl=""
          local _si _sd _sm _ss
          IFS=$'\t' read -r _si _sd _sm _ss <<< "$_sl"
          if [ "${_sm:-0}" != "$mtime" ] \
             || [ "${_ss:-0}" != "$size" ] \
             || [ "${_si:-0}:${_sd:-0}" != "${_inode:-0}:${_dev:-0}" ]; then
            changed=1; reason="meta-stat-changed"; break
          fi
        done < "$metaf"
      fi

      if [ "$changed" -eq 0 ]; then
        printf '%s\0' "$d" >> "$plan_skipped_file"
        vlog "PLAN: skip $d reason=$reason"
        return
      fi
    else
      if [ ! -f "$metaf" ]; then
        reason="meta-missing"
      else
        reason="meta-invalid"
      fi
      local md5_details="${VERIFY_MD5_DETAILS:-1}"
      if [ "$md5_details" -eq 1 ] && [ -f "$sumf" ]; then
        local vr
        vr=$(emit_md5_file_details "$d" "$sumf"; printf '%s' "$?")
        emit_md5_detail "$d" "$vr"
      fi
    fi

    reason="${reason:-needs-recompute}"
    printf '%s\0' "$d" >> "$plan_to_process_file"
    vlog "PLAN: process $d reason=$reason"
  else
    reason="no-sumfile"
    printf '%s\0' "$d" >> "$plan_to_process_file"
    vlog "PLAN: process $d reason=$reason"
  fi
}

# Sequential planning: iterate directories, mutate plan files directly.
_plan_sequential() {
  local plan_to_process_file="$1" plan_skipped_file="$2"
  for d in "${_plan_dirs[@]}"; do
    _plan_one_directory "$d"
  done
}

# Parallel planning: dispatch directories to subshell workers, aggregate results.
_plan_parallel() {
  local plan_to_process_file="$1" plan_skipped_file="$2"
  local _plan_results_dir
  _plan_results_dir="$(mktemp -d "${TMPDIR:-/tmp}/plan_par.XXXXXX")"
  DIR_PIDS=(); DIR_PIDS_COUNT=0
  local _plan_idx=0
  local _real_run_log="${RUN_LOG:-}"

  for d in "${_plan_dirs[@]}"; do
    _dir_par_maybe_wait
    local _pw="$_plan_results_dir/worker_${_plan_idx}"
    (
      # Redirect plan files and RUN_LOG to per-worker temps
      plan_to_process_file="$_pw.proc"
      plan_skipped_file="$_pw.skip"
      RUN_LOG="$_pw.runlog"
      : > "$plan_to_process_file"
      : > "$plan_skipped_file"
      : > "$RUN_LOG"
      _plan_one_directory "$d"
    ) &
    DIR_PIDS+=("$!")
    DIR_PIDS_COUNT=${#DIR_PIDS[@]}
    _plan_idx=$((_plan_idx+1))
  done

  _dir_par_wait_all

  # Aggregate in submission order (preserves find|sort directory order)
  local i
  for (( i=0; i<_plan_idx; i++ )); do
    local _pw="$_plan_results_dir/worker_${i}"
    [ -s "$_pw.proc" ] && cat "$_pw.proc" >> "$plan_to_process_file"
    [ -s "$_pw.skip" ] && cat "$_pw.skip" >> "$plan_skipped_file"
    [ -s "$_pw.runlog" ] && cat "$_pw.runlog" >> "$_real_run_log"
  done

  rm -rf "$_plan_results_dir" 2>/dev/null || true
}