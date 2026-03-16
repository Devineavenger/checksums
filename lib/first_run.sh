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
#
# first_run.sh
#
# First-run verification logic and md5 verification helper.
# Modified to make first-run verification non-destructive:
# - It only verifies and records directories that should be overwritten.
# - Actual overwrites are scheduled in the global array first_run_overwrite
#   and must be executed later (after user confirmation) by the orchestrator.
#
# Behavior preserved:
# - Verification logs and FIRST_RUN_LOG entries remain unchanged.
# - In verify-only or dry-run modes, no overwrites are performed; entries are logged/scheduled only.
#
# vX.Y (custom): first-run is read-only and schedules overwrites instead of running them immediately.

# Ensure the scheduled-overwrite array exists (global)
first_run_overwrite=()

verify_md5_file() {
  local dir="$1"
  local sumf
  sumf="$(_sidecar_path "$dir" "$SUM_FILENAME")"
  [ -f "$sumf" ] || return 2
  vlog "Verifying $sumf"

  if [ "${PER_FILE_ALGO:-md5}" = "md5" ] && command -v md5sum >/dev/null 2>&1; then
    # Try GNU md5sum check first (only valid for md5 manifests)
    if md5sum --check --status "$sumf" >/dev/null 2>&1; then
      return 0
    fi
    # If that fails, fall back to parsing manually (handles BSD format too)
  fi

  local missing=0 bad=0 expected fname actual
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue

    case "$entry" in
      MD5*=*)  # BSD/macOS format: MD5 (filename) = hash
        fname=$(printf '%s' "$entry" | sed -E 's/^MD5 \((.*)\) = .*/\1/')
        expected=$(printf '%s' "$entry" | awk '{print $NF}')
        ;;
      *)        # GNU format: hash␣␣filename (tolerate one or more spaces)
        expected=${entry%%[[:space:]]*}
        fname=${entry#"$expected"}
        # strip leading spaces and optional leading '*'
        fname=$(printf '%s' "$fname" | sed -E 's/^[[:space:]]+[*[:space:]]*//')
        ;;
    esac

    local fpath="$dir/$fname"
    if [ ! -e "$fpath" ]; then
      missing=1
      [ -n "$FIRST_RUN_LOG" ] && printf 'MISSING: %s\n' "$fpath" >> "$FIRST_RUN_LOG"
      [ -n "$RUN_LOG" ] && printf 'MISSING: %s\n' "$fpath" >> "$RUN_LOG"
      continue
    fi

    if ! actual=$(file_hash "$fpath" "${PER_FILE_ALGO:-md5}"); then
      bad=1
      [ -n "$FIRST_RUN_LOG" ] && printf 'UNREADABLE: %s\n' "$fpath" >> "$FIRST_RUN_LOG"
      [ -n "$RUN_LOG" ] && printf 'UNREADABLE: %s\n' "$fpath" >> "$RUN_LOG"
      continue
    fi
    if [ "$actual" != "$expected" ]; then
      bad=1
      [ -n "$FIRST_RUN_LOG" ] && \
        printf 'MISMATCH: %s\texpected=%s\tactual=%s\n' "$fpath" "$expected" "$actual" >> "$FIRST_RUN_LOG"
      [ -n "$RUN_LOG" ] && \
        printf 'MISMATCH: %s\texpected=%s\tactual=%s\n' "$fpath" "$expected" "$actual" >> "$RUN_LOG"
    fi
  done < "$sumf"

  if [ "$missing" -eq 0 ] && [ "$bad" -eq 0 ]; then
    return 0
  elif [ "$missing" -ne 0 ]; then
    return 2
  else
    return 1
  fi
}

# Worker: process a single directory for first-run verification.
# When results_file is non-empty, writes structured results to it (parallel mode).
# When results_file is empty, mutates globals directly (sequential mode).
_first_run_verify_one() {
  local d="$1" results_file="$2"

  first_run_log "Verifying directory: $d"
  dir_log_append "$d" "Verifying existing checksums in: $d"
  if verify_md5_file "$d"; then
    first_run_log "Verified OK: $d"
    dir_log_append "$d" "Verified OK: $d"
    if [ -n "$results_file" ]; then
      printf 'COUNTER:count_verified:1\n' >> "$results_file"
    else
      count_verified=$((count_verified+1))
    fi

    if has_files "$d"; then
      if [ "$DRY_RUN" -eq 1 ] || [ "$VERIFY_ONLY" -eq 1 ]; then
        first_run_log "DRY/VERIFY: meta/log creation suppressed for $d"
      else
        first_run_log "SCHEDULED: would create meta/log for $d"
        if [ -n "$results_file" ]; then
          printf 'OVERWRITE:%s\n' "$d" >> "$results_file"
        else
          first_run_overwrite+=("$d")
        fi
        dir_log_append "$d" "SCHEDULED OVERWRITE by first-run"
      fi
    else
      first_run_log "SKIPPED scheduling for empty/container-only directory: $d"
      dir_log_append "$d" "SKIPPED scheduling (no user files)"
    fi
    return 0
  fi

  # mismatch detected
  first_run_log "Verification FAILED for $d"
  dir_log_append "$d" "Verification FAILED for $d"

  case "$FIRST_RUN_CHOICE" in
    skip)
      first_run_log "CHOICE skip: recorded mismatch for $d"
      if [ -n "$results_file" ]; then
        printf 'ERROR:First-run: skipped %s due to checksum mismatch\n' "$d" >> "$results_file"
      else
        record_error "First-run: skipped $d due to checksum mismatch"
      fi
      ;;
    overwrite)
      if [ "$VERIFY_ONLY" -eq 1 ]; then
        first_run_log "CHOICE overwrite suppressed in verify-only for $d"
        if [ -n "$results_file" ]; then
          printf 'ERROR:First-run: overwrite requested but skipped (verify-only) for %s\n' "$d" >> "$results_file"
        else
          record_error "First-run: overwrite requested but skipped (verify-only) for $d"
        fi
        return 0
      fi

      if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "${FORCE_REBUILD:-0}" -eq 0 ] && [ "${VERIFY_ONLY:-0}" -eq 0 ]; then
        if ! has_files "$d"; then
          first_run_log "SKIPPED scheduling overwrite for empty directory: $d"
          dir_log_append "$d" "SKIPPED scheduling overwrite (no user files)"
          return 0
        fi
      fi

      first_run_log "CHOICE overwrite: scheduling recomputation for $d"
      dir_log_append "$d" "Scheduled auto-overwrite: recomputing for $d"
      if [ "$DRY_RUN" -eq 1 ]; then
        first_run_log "DRYRUN: would overwrite $(_sidecar_path "$d" "$SUM_FILENAME")"
        vlog "DRYRUN: would overwrite $(_sidecar_path "$d" "$SUM_FILENAME")"
      else
        if [ -n "$results_file" ]; then
          printf 'OVERWRITE:%s\n' "$d" >> "$results_file"
          printf 'COUNTER:count_overwritten:1\n' >> "$results_file"
        else
          first_run_overwrite+=("$d")
          first_run_log "SCHEDULED OVERWRITE for $d"
          dir_log_append "$d" "SCHEDULED OVERWRITE by first-run"
          count_overwritten=$((count_overwritten+1))
        fi
      fi
      ;;
    prompt)
      # Prompt mode always runs sequentially; this path is only called from sequential.
      while true; do
        printf '%bDirectory %s has mismatched checksums. Choose action: [s]kip, [o]verwrite, [a]bort:%b ' "${_C_BOLD}" "$d" "${_C_RST}"
        if ! IFS= read -r choice; then choice="s"; fi
        case "$choice" in
          s|S)
            first_run_log "CHOICE skip for $d"
            record_error "First-run: skipped $d due to checksum mismatch"
            break
            ;;
          o|O)
            if [ "$VERIFY_ONLY" -eq 1 ]; then
              first_run_log "CHOICE overwrite suppressed in verify-only for $d"
              record_error "First-run: overwrite requested but skipped (verify-only) for $d"
              break
            fi

            if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "${FORCE_REBUILD:-0}" -eq 0 ] && [ "${VERIFY_ONLY:-0}" -eq 0 ]; then
              if ! has_files "$d"; then
                first_run_log "SKIPPED scheduling overwrite for empty directory (prompt): $d"
                dir_log_append "$d" "SKIPPED scheduling overwrite (no user files)"
                break
              fi
            fi

            first_run_log "CHOICE overwrite for $d"
            if [ "$DRY_RUN" -eq 1 ]; then
              first_run_log "DRYRUN: would overwrite $(_sidecar_path "$d" "$SUM_FILENAME")"
              vlog "DRYRUN: would overwrite $(_sidecar_path "$d" "$SUM_FILENAME")"
            else
              first_run_overwrite+=("$d")
              first_run_log "SCHEDULED OVERWRITE for $d"
              count_overwritten=$((count_overwritten+1))
            fi
            break
            ;;
          a|A)
            first_run_log "CHOICE abort at $d"
            log "User aborted at first-run mismatch in $d"
            exit 2
            ;;
          *) printf '%bPlease enter s, o, or a%b\n' "${_C_DIM}" "${_C_RST}" ;;
        esac
      done
      ;;
    *)
      first_run_log "Unknown FIRST_RUN_CHOICE='$FIRST_RUN_CHOICE'; treating as skip for $d"
      if [ -n "$results_file" ]; then
        printf 'ERROR:First-run: unknown choice for %s; skipped\n' "$d" >> "$results_file"
      else
        record_error "First-run: unknown choice for $d; skipped"
      fi
      ;;
  esac
}

# Sequential path: iterate targets and mutate globals directly (existing behavior).
_first_run_verify_sequential() {
  for d in "${targets[@]}"; do
    _first_run_verify_one "$d" ""
  done
}

# Parallel path: dispatch each directory to a subshell worker.
_first_run_verify_parallel() {
  local _fr_results_dir
  _fr_results_dir="$(mktemp -d "${TMPDIR:-/tmp}/fr_verify.XXXXXX")"
  DIR_PIDS=(); DIR_PIDS_COUNT=0
  local _fr_idx=0
  local _real_first_run_log="$FIRST_RUN_LOG"
  local _real_run_log="$RUN_LOG"

  for d in "${targets[@]}"; do
    _dir_par_maybe_wait
    local _fr_out="$_fr_results_dir/worker_${_fr_idx}"
    (
      # Redirect log files to per-worker temps so writes don't interleave
      FIRST_RUN_LOG="$_fr_out.frlog"
      RUN_LOG="$_fr_out.runlog"
      : > "$FIRST_RUN_LOG"
      : > "$RUN_LOG"
      _first_run_verify_one "$d" "$_fr_out.result"
    ) &
    DIR_PIDS+=("$!")
    DIR_PIDS_COUNT=${#DIR_PIDS[@]}
    _fr_idx=$((_fr_idx+1))
  done

  _dir_par_wait_all

  # Aggregate results in submission order (preserves deterministic output)
  local i
  for (( i=0; i<_fr_idx; i++ )); do
    local _fr_out="$_fr_results_dir/worker_${i}"
    # Replay log files into the real logs
    [ -s "$_fr_out.frlog" ] && cat "$_fr_out.frlog" >> "$_real_first_run_log"
    [ -s "$_fr_out.runlog" ] && cat "$_fr_out.runlog" >> "$_real_run_log"
    # Parse structured results
    [ -f "$_fr_out.result" ] || continue
    while IFS= read -r _line; do
      case "$_line" in
        COUNTER:count_verified:*)   count_verified=$((count_verified + ${_line##*:})) ;;
        COUNTER:count_overwritten:*) count_overwritten=$((count_overwritten + ${_line##*:})) ;;
        OVERWRITE:*)                first_run_overwrite+=("${_line#OVERWRITE:}") ;;
        ERROR:*)                    record_error "${_line#ERROR:}" ;;
      esac
    done < "$_fr_out.result"
  done

  rm -rf "$_fr_results_dir" 2>/dev/null || true
}

first_run_verify() {
  local base="$1"
  local -a targets=()

  # Collect directories that contain an .md5 and have at least one sidefile missing.
  # When STORE_DIR is set, manifests live there; map store paths back to source dirs.
  local _fr_search_base="$base"
  [ -n "${STORE_DIR:-}" ] && [ -d "${STORE_DIR:-}" ] && _fr_search_base="$STORE_DIR"

  # Bash 3.x lacks associative arrays; guard declare -A and provide a simple fallback.
  if declare -p -A >/dev/null 2>&1; then
    # Bash >= 4: use an assoc set to avoid duplicate targets.
    declare -A _fr_seen=()
    while IFS= read -r -d '' f; do
      local d; d=$(dirname "$f")
      # Map store path back to source directory when using STORE_DIR
      if [ -n "${STORE_DIR:-}" ]; then
        local _rel="${d#"${STORE_DIR%/}"}"
        _rel="${_rel#/}"
        if [ -z "$_rel" ]; then
          d="${base%/}"
        else
          d="${base%/}/$_rel"
        fi
      fi
      [ -d "$d" ] || continue
      # Select if either .meta OR .log is missing
      if [ ! -f "$(_sidecar_path "$d" "$META_FILENAME")" ] || [ ! -f "$(_sidecar_path "$d" "$LOG_FILENAME")" ]; then
        if [ -z "${_fr_seen[$d]:-}" ]; then
          targets+=("$d")
          _fr_seen["$d"]=1
        fi
      fi
    done < <(_find "$_fr_search_base" -type f -name "$SUM_FILENAME" -print0 | LC_ALL=C sort -z)
  else
    # Bash < 4: use a space-delimited "seen_list" to prevent duplicates.
    local seen_list=""
    while IFS= read -r -d '' f; do
      local d; d=$(dirname "$f")
      if [ -n "${STORE_DIR:-}" ]; then
        local _rel="${d#"${STORE_DIR%/}"}"
        _rel="${_rel#/}"
        if [ -z "$_rel" ]; then
          d="${base%/}"
        else
          d="${base%/}/$_rel"
        fi
      fi
      [ -d "$d" ] || continue
      if [ ! -f "$(_sidecar_path "$d" "$META_FILENAME")" ] || [ ! -f "$(_sidecar_path "$d" "$LOG_FILENAME")" ]; then
        case " $seen_list " in
          *" $d "*) ;;               # already present
          *) targets+=("$d"); seen_list="$seen_list $d" ;;
        esac
      fi
    done < <(_find "$_fr_search_base" -type f -name "$SUM_FILENAME" -print0 | LC_ALL=C sort -z)
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    log "First-run: no existing $SUM_FILENAME needing verification found."
    return 0
  fi

  FIRST_RUN_LOG="$(_runlog_path "${LOG_BASE:-$BASE_NAME}.first-run.log")"
  : > "$FIRST_RUN_LOG"
  log "First-run: found ${#targets[@]} directories; detailed first-run log: $FIRST_RUN_LOG"
  first_run_log "First-run start: base=$base  files: ${#targets[@]}"

  # --- Parallel or sequential dispatch ---
  if [ "${PARALLEL_JOBS:-1}" -gt 1 ] && [ "$FIRST_RUN_CHOICE" != "prompt" ]; then
    _first_run_verify_parallel "$@"
  else
    _first_run_verify_sequential
  fi

  first_run_log "First-run completed."
  return 0
}
