#!/usr/bin/env bash
# orchestrator.sh
# shellcheck source=lib/init.sh
# shellcheck source=lib/logging.sh
# shellcheck source=lib/process.sh
# shellcheck disable=SC2034,SC2154
#
# Orchestrator: top-level run orchestration for checksums tool.
#
# Responsibilities:
#  - Build exclusion lists used by discovery helpers
#  - Set up run-level logging and runtime flags
#  - Detect required external tools and platform stat flavour
#  - Present a quick preview to the user and prompt for confirmation
#  - Run first-run verification (when requested) and collect scheduled overwrites
#  - Perform accurate planning (which directories truly need processing)
#  - Emit skip logs for directories determined to be up-to-date
#  - Execute per-directory processing (process_single_directory) for planned directories
#  - Perform scheduled first-run overwrites after first-run verification
#  - Clean up leftover lockfiles and emit a final summary
#
# Implementation notes and rationale:
#  - Quick preview is intentionally lightweight and forgiving; it enumerates
#    directories without heavy disk I/O so the prompt can be shown quickly.
#  - Accurate planning is slower but avoids unnecessary work: it verifies meta
#    signatures, compares mtimes/sizes, and counts files vs manifest lines.
#  - Skip logging (dir_log_skip) rotates/truncates per-directory logs for
#    directories that will be skipped. We avoid clobbering logs for directories
#    that we know will be processed later (first-run scheduled overwrites or
#    those in plan_to_process or those already processed).
#  - To avoid confusing logs (and subtle races), we evaluate directory existence
#    once into a variable (exists_yesno) and use that value both for the human
#    oriented ORCH log line and for the conditional that decides whether to
#    call process_single_directory. This keeps the log truthful and in sync
#    with the actual control flow.
#
# Assumptions:
#  - The other modules (fs.sh, tools.sh, stat.sh, logging.sh, meta.sh, process.sh,
#    compat.sh, first_run.sh, args.sh, usage.sh) are already sourced by the
#    top-level entrypoint before run_checksums is invoked.
#  - Global variables such as TARGET_DIR, BASE_NAME, MD5_FILENAME, etc., are
#    initialized by init.sh or via CLI/config handling performed earlier.

run_checksums() {
  RUN_LOG="$TARGET_DIR/${LOG_BASE:-$BASE_NAME}.run.log"
  LOG_FILEPATH="$RUN_LOG"
  : > "$RUN_LOG"

  if [ "$DEBUG" -gt 0 ]; then
    log_level=3
  elif [ "$VERBOSE" -ge 2 ]; then
    log_level=3   # -vv or higher unlocks debug
  elif [ "$VERBOSE" -gt 0 ]; then
    log_level=2   # single -v = verbose only
  fi

  detect_tools
  detect_stat
  check_bash_version

  if ! check_required_tools; then fatal "Missing tools; see run log for hints."; fi

  cd "$TARGET_DIR" || fatal "Cannot cd to $TARGET_DIR"
  TARGET_DIR=$(pwd -P)
  cd - >/dev/null 2>&1 || true
  [ "$TARGET_DIR" = "/" ] && fatal "Refusing to run on system root"

  # Load config before parsing CLI so CLI overrides config values.
  if [ -n "$CONFIG_FILE" ]; then
    if [ -f "$CONFIG_FILE" ]; then
      log "Loading config from explicit file $CONFIG_FILE"
      # shellcheck source=/dev/null
      . "$CONFIG_FILE"
    else
      fatal "Config file specified but not found: $CONFIG_FILE"
    fi
  else
    DEFAULT_CONF="$TARGET_DIR/${BASE_NAME}.conf"
    if [ -f "$DEFAULT_CONF" ]; then
      log "Loading config from default $DEFAULT_CONF"
      # shellcheck source=/dev/null
      . "$DEFAULT_CONF"
    fi
  fi

  # NOTE: Exclusion globals (MD5_EXCL/META_EXCL/LOG_EXCL/etc.) are required by fs helpers.
  # Ensure they are initialized even if build_exclusions hasn't run yet. This prevents
  # unset-variable issues when helpers are called before the standard build step.
  if [ -z "${MD5_EXCL:-}" ] || [ -z "${META_EXCL:-}" ] || [ -z "${LOG_EXCL:-}" ]; then
    dbg "Calling build_exclusions early to initialize exclusion globals"
    build_exclusions
  fi

  # Build exclusions again after CLI/config to reflect any changes to BASE_NAME/LOG_BASE.
  # This keeps derived basenames aligned with user-provided flags.
  build_exclusions

  # Initialize adaptive batch thresholds once per run to avoid repeated numfmt conversions.
  # This reduces overhead when classifying batch sizes for many files.
  init_batch_thresholds

  # Explicit notice when reuse heuristics are disabled
  if [ "${NO_REUSE:-0}" -eq 1 ]; then
    log "NO_REUSE=1: disabling reuse heuristics, all files will be rehashed"
  fi
  log "Starting run on $TARGET_DIR"
  log "Run ID: $RUN_ID"
  log "Base: $BASE_NAME  per-file: $PER_FILE_ALGO  meta-sig: $META_SIG_ALGO  dry-run: $DRY_RUN  first-run: $FIRST_RUN choice: $FIRST_RUN_CHOICE  parallel: $PARALLEL_JOBS  format: $LOG_FORMAT  verify-only: $VERIFY_ONLY"

  # ----------------------------
  # Quick preview (very fast)
  # ----------------------------
  local preview_proc_file preview_skipped_file
  preview_proc_file="$(mktemp)" || fatal "mktemp failed"
  preview_skipped_file="$(mktemp)" || fatal "mktemp failed"
  decide_quick_plan "$TARGET_DIR" "$preview_proc_file" "$preview_skipped_file"

  local -a preview_proc=() preview_skipped=()
  while IFS= read -r -d '' d; do preview_proc+=("$d"); done < "$preview_proc_file"
  while IFS= read -r -d '' d; do preview_skipped+=("$d"); done < "$preview_skipped_file"

  echo "Found ${#preview_proc[@]} folder(s) to process (preview):"
  local i=0 max_preview=200
  for d in "${preview_proc[@]}"; do
    [ "$i" -ge "$max_preview" ] && break
    echo "  * $d"
    i=$((i+1))
  done
  if [ "${#preview_proc[@]}" -gt "$max_preview" ]; then
    echo "  ... and $(( ${#preview_proc[@]} - max_preview )) more"
  fi

  echo "Skipping ${#preview_skipped[@]} folder(s) (preview):"
  i=0
  for d in "${preview_skipped[@]}"; do
    [ "$i" -ge "$max_preview" ] && break
    echo "  * $d"
    i=$((i+1))
  done
  if [ "${#preview_skipped[@]}" -gt "$max_preview" ]; then
    echo "  ... and $(( ${#preview_skipped[@]} - max_preview )) more"
  fi

  rm -f "$preview_proc_file" "$preview_skipped_file"

  # Count preview totals (fast approximate)
  if [ "${#preview_proc[@]}" -gt 0 ]; then
    # Single pass: count NULs across all to‑process dirs
    # Faster and fewer forks than per‑dir loops; preserves "approximate" semantics
    # Use -L only if desirable globally; otherwise default to non-following for performance
    # Note: find –print0 paths are concatenated via xargs to avoid hitting ARG_MAX
    total_files_preview=$(
      printf '%s\0' "${preview_proc[@]}" \
        | tr '\n' '\0' \
        | xargs -0 -r -n1 -I{} find "{}" -maxdepth 1 -type f -print0 2>/dev/null \
        | tr -cd '\0' \
        | wc -c
    )
  else
    total_files_preview=0
  fi
  echo "total files (preview): $total_files_preview"

  # ----------------------------
  # Prompt (after preview)
  # ----------------------------
  if [ "$YES" -eq 0 ] && [ "$ASSUME_NO" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
    printf 'About to process directories under %s. Continue? [y/N]: ' "$TARGET_DIR"
    if ! IFS= read -r ans; then exit 1; fi
    case "$ans" in [Yy]*) ;; *) log "Aborted by user"; exit 0 ;; esac
  elif [ "$ASSUME_NO" -eq 1 ]; then
    log "Aborted by assume-no mode"
    exit 0
  fi

  # ----------------------------
  # First-run verification (post confirmation)
  # ----------------------------
  if [ "$FIRST_RUN" -eq 1 ]; then
    # ensure MAP_first_run_overwrite exists for non-assoc fallback
    if [ "${USE_ASSOC:-0}" -eq 0 ] && [ -z "${MAP_first_run_overwrite:-}" ]; then
      MAP_first_run_overwrite="$(mktemp)"; : > "$MAP_first_run_overwrite"
    fi
    first_run_verify "$TARGET_DIR"
    # when first_run_verify schedules entries it appended to first_run_overwrite and also
    # set the lookup (first_run_overwrite_set or MAP_first_run_overwrite). If not, ensure any
    # array entries are reflected into the lookup so later stages consult it.
    # Build a fast lookup for scheduled first-run overwrites (assoc-array or text-map fallback)
    if [ "${USE_ASSOC:-0}" -eq 1 ]; then
      # Ensure the associative array exists (safe to run repeatedly)
      declare -gA first_run_overwrite_set 2>/dev/null || true
      # Clear any previous contents without changing type
      unset first_run_overwrite_set
      declare -gA first_run_overwrite_set
      for d in "${first_run_overwrite[@]:-}"; do
        [ -n "$d" ] && first_run_overwrite_set["$d"]=1
      done
    else
      # Ensure the map file exists and is empty if not already set
      if [ -z "${MAP_first_run_overwrite:-}" ]; then
        MAP_first_run_overwrite="$(mktemp)" && : > "$MAP_first_run_overwrite"
      fi
      for d in "${first_run_overwrite[@]:-}"; do
        map_set "$MAP_first_run_overwrite" "$d" "1"
      done
    fi
  fi
  
  # track directories that have actually been processed during this run
  local -a processed_dirs=()

  # Perform scheduled overwrites now
  if [ "${#first_run_overwrite[@]}" -gt 0 ]; then
    log "First-run: performing ${#first_run_overwrite[@]} scheduled overwrite(s)"
    for d in "${first_run_overwrite[@]}"; do
      # Evaluate existence exactly once to avoid mismatched subshell checks or races
      if [ -d "$d" ]; then
        exists_yesno=yes
      else
        exists_yesno=no
      fi
      log "ORCH: about to call process_single_directory for $d (exists=$exists_yesno)"
      if [ "$exists_yesno" = yes ]; then
        process_single_directory "$d"
        # After processing, remove from the scheduled lookup so SKIP_EMPTY resumes normal behavior
        if [ -n "$d" ]; then
          if [ "${USE_ASSOC:-0}" -eq 1 ]; then
            log "DEBUG: removing scheduled overwrite entry for d='$d'"
            unset "first_run_overwrite_set[$d]"
          else
		    log "DEBUG: post-process cleanup for d='${d}' USE_ASSOC=${USE_ASSOC}"
            map_del "$MAP_first_run_overwrite" "$d"
          fi
        fi
        count_overwritten=$((count_overwritten+1))
        count_processed=$((count_processed+1))
        processed_dirs+=("$d")
      else
        record_error "First-run scheduled overwrite target missing: $d"
      fi
    done
    first_run_overwrite=()
  fi

  # ----------------------------
  # Full accurate planning (may be slow)
  # ----------------------------
  local plan_to_process_file plan_skipped_file
  plan_to_process_file="$(mktemp)" || fatal "mktemp failed"
  plan_skipped_file="$(mktemp)" || fatal "mktemp failed"
  decide_directories_plan "$TARGET_DIR" "$plan_to_process_file" "$plan_skipped_file"

  local -a plan_to_process=() plan_skipped=()
  while IFS= read -r -d '' d; do plan_to_process+=("$d"); done < "$plan_to_process_file"
  while IFS= read -r -d '' d; do plan_skipped+=("$d"); done < "$plan_skipped_file"

  # Emit skip logs now (rotation + header) for skipped directories,
  # but honor NO_ROOT_SIDEFILES and SKIP_EMPTY so root and empty/container-only dirs stay untouched.
  # helper: test membership in an array
  _in_array() {
    local needle="$1"; shift
    for e in "$@"; do [ "$e" = "$needle" ] && return 0; done
    return 1
  }

  for d in "${plan_skipped[@]}"; do
    # still respect root/empty guards
    if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ "$d" = "${TARGET_DIR%/}" ]; then
      count_skipped=$((count_skipped+1)); continue
    fi
    if [ "${SKIP_EMPTY:-1}" -eq 1 ] && ! has_files "$d"; then
      count_skipped=$((count_skipped+1)); continue
    fi

    # If this directory is scheduled for first-run overwrite, planned-to-process,
    # or was already processed earlier in this run, do not write the skip block now.
    if _in_array "$d" "${first_run_overwrite[@]:-}" || _in_array "$d" "${plan_to_process[@]:-}" || _in_array "$d" "${processed_dirs[@]:-}"; then
      count_skipped=$((count_skipped+1))
      continue
    fi

    # Safe to write skip-log: not scheduled and not going to be processed
    dir_log_skip "$d"
    count_skipped=$((count_skipped+1))
  done

  # Process planned directories
  log "Directories to process: ${#plan_to_process[@]}"
  for d in "${plan_to_process[@]}"; do
    # Evaluate existence once for logging and action
    if [ -d "$d" ]; then
      exists_yesno=yes
    else
      exists_yesno=no
    fi
    log "ORCH: about to call process_single_directory for $d (exists=$exists_yesno)"
    if [ "$exists_yesno" = yes ]; then
      process_single_directory "$d"
      count_processed=$((count_processed+1))
      processed_dirs+=("$d")
    else
      record_error "Planned processing target missing: $d"
    fi
  done

  rm -f "$plan_to_process_file" "$plan_skipped_file"

  cleanup_leftover_locks "$TARGET_DIR"

  # === Central summary report ===
  log "Summary:"
  log "  Verified:    $count_verified"
  log "  Processed:   $count_processed"
  log "  Skipped:     $count_skipped"
  log "  Overwritten: $count_overwritten"
  log "  Errors:      $count_errors"

  if [ "${#errors[@]}" -gt 0 ]; then
    log "Completed with ${#errors[@]} errors. See run log ${RUN_LOG} and first-run log ${FIRST_RUN_LOG:-none}"
    for e in "${errors[@]}"; do _global_log 0 "ERR: $e"; done
    exit 1
  fi

  log "Completed successfully."
  exit 0
}
