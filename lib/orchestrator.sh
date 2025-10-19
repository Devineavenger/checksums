#!/usr/bin/env bash
# orchestrator.sh
# shellcheck source=lib/init.sh
# shellcheck source=lib/logging.sh
# shellcheck source=lib/process.sh
# shellcheck disable=SC2034,SC2154
#
# Orchestrator: planning (quick preview), prompt, accurate planning,
# then skip logging and execution. first_run_verify is called after
# confirmation. Any scheduled overwrites from first_run_verify are
# executed by the orchestrator now.
# Extracted (verbatim behavior) from checksums.sh v2.12.5.
#
# Notes:
# - All behavior is preserved: quick preview, prompt, first-run scheduling,
#   accurate planning, dir skip logging, processing, cleanup, and summary.
# - This file assumes the rest of the modules (fs.sh, tools.sh, stat.sh, logging.sh,
#   meta.sh, process.sh, compat.sh, first_run.sh, args.sh, usage.sh) are already sourced.

run_checksums() {
  build_exclusions

  RUN_LOG="$TARGET_DIR/${LOG_BASE:-$BASE_NAME}.run.log"
  LOG_FILEPATH="$RUN_LOG"
  : > "$RUN_LOG"

  [ "$DEBUG" -gt 0 ] && log_level=3
  [ "$VERBOSE" -gt 0 ] && [ "$DEBUG" -eq 0 ] && log_level=2

  detect_tools
  detect_stat
  check_bash_version

  if ! check_required_tools; then fatal "Missing tools; see run log for hints."; fi

  cd "$TARGET_DIR" || fatal "Cannot cd to $TARGET_DIR"
  TARGET_DIR=$(pwd -P)
  cd - >/dev/null 2>&1 || true
  [ "$TARGET_DIR" = "/" ] && fatal "Refusing to run on system root"

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
  local total_files_preview=0
  for d in "${preview_proc[@]}"; do
    while IFS= read -r -d '' _; do
      total_files_preview=$((total_files_preview+1))
    done < <(find -L "$d" -maxdepth 1 -type f -print0 2>/dev/null || find "$d" -maxdepth 1 -type f -print0 2>/dev/null)
  done
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
    first_run_verify "$TARGET_DIR"
  fi

  # Perform scheduled overwrites now
  if [ "${#first_run_overwrite[@]}" -gt 0 ]; then
    log "First-run: performing ${#first_run_overwrite[@]} scheduled overwrite(s)"
    for d in "${first_run_overwrite[@]}"; do
      if [ -d "$d" ]; then
        process_single_directory "$d"
        count_overwritten=$((count_overwritten+1))
        count_processed=$((count_processed+1))
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
  for d in "${plan_skipped[@]}"; do
    if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ "$d" = "${TARGET_DIR%/}" ]; then
      count_skipped=$((count_skipped+1))
      continue
    fi
    if [ "${SKIP_EMPTY:-1}" -eq 1 ] && ! find "$d" -type f -print -quit 2>/dev/null | grep -q .; then
      count_skipped=$((count_skipped+1))
      continue
    fi
    dir_log_skip "$d"
    count_skipped=$((count_skipped+1))
  done

  # Process planned directories
  log "Directories to process: ${#plan_to_process[@]}"
  for d in "${plan_to_process[@]}"; do
    process_single_directory "$d"
    count_processed=$((count_processed+1))
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
