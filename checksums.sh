#!/usr/bin/env bash
# shellcheck disable=SC2034
# Version: 2.12.0

#
# checksums.sh
#
# Modular checksum manager with parallel + inode incremental hashing
#
# v2.1: summary report, structured logs, log rotation
# v2.2: verification-only mode (-V), audit trail with run ID
# v2.3: config file support, skip/include patterns, non-interactive modes, 2-log rotation
# v2.3.1: --config FILE option and default <BASE_NAME>.conf
# v2.4: cross-platform stat abstraction, Bash 3.2 fallback for associative arrays
# v2.7 (custom): print pre-processing summary before confirmation and side effects.
# v2.8 (custom): added count_processed and included it in final summary.
# v2.9 (custom): added quick preview planner to show immediate list before heavy checks.
# v2.10 (custom): defer first_run_verify until after preview and user confirmation.
# v2.11 (custom): first_run_verify is non-destructive and schedules overwrites; orchestrator performs them.

set -euo pipefail
shopt -s nullglob

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER="$(cat "$BASE_DIR/VERSION" 2>/dev/null || echo "2.4.0")"
ME="$(basename "$0")"

# === Defaults (can be overridden by config file or CLI) ===
BASE_NAME="#####checksums#####"   # Base name for generated files (.md5, .meta, .log)
PER_FILE_ALGO="md5"               # Algorithm for per-file checksums: "md5" (default) or "sha256"
META_SIG_ALGO="sha256"            # Algorithm for meta signature: "sha256" (default), "md5", or "none"
LOG_BASE=""                       # Base name for run logs; defaults to BASE_NAME if not set
DRY_RUN=0                         # If 1, simulate actions without writing files (-n)
DEBUG=0                           # Debug verbosity level (-d, repeatable)
VERBOSE=0                         # Verbose logging (-v)
YES=0                             # Auto-confirm prompts (-y or --assume-yes)
ASSUME_NO=0                       # Auto-decline prompts (--assume-no)
FORCE_REBUILD=0                   # Force rebuild of checksums, ignoring manifests (-r)
FIRST_RUN=0                       # First-run verification mode (-F)
FIRST_RUN_CHOICE="prompt"         # Action on mismatch in first-run: "skip", "overwrite", or "prompt" (-C)
PARALLEL_JOBS=1                   # Number of parallel hashing jobs (-p N)
LOG_FORMAT="text"                 # Log output format: "text" (default), "json", or "csv" (-o)
VERIFY_ONLY=0                     # Verification-only audit mode (-V); no writes, just checks
CONFIG_FILE=""                    # explicit config file path (--config FILE)

# === Filenames (set later based on BASE_NAME/LOG_BASE) ===
MD5_FILENAME=""                   # Will become "<BASE_NAME>.md5"
META_FILENAME=""                  # Will become "<BASE_NAME>.meta"
LOG_FILENAME=""                   # Will become "<LOG_BASE>.log"
LOCK_SUFFIX=".lock"               # Suffix for transient lock files

# === Exclusions (patterns to skip when scanning a directory) ===
MD5_EXCL="" META_EXCL="" LOG_EXCL="" LOCK_EXCL=""

# === Tool detection flags (set in detect_tools) ===
TOOL_md5_cmd=""                   # Command for md5 (md5sum or md5 -r)
TOOL_sha256=""                    # Command for sha256sum
TOOL_shasum=""                    # Command for shasum -a 256
TOOL_stat_gnu=0                   # retained for compatibility with older modules (not used in 2.4)
TOOL_flock=0                      # 1 if flock is available, else 0

# === Logging state ===
RUN_LOG=""                        # Path to run-level log
LOG_FILEPATH=""                   # Current log file being written
FIRST_RUN_LOG=""                  # Path to first-run verification log

errors=()                         # Array of error messages collected during run
log_level=1                       # Default log verbosity level

# === Summary counters (for central report) ===
count_verified=0                  # Directories verified OK
count_processed=0                 # Directories processed (had processing run)
count_skipped=0                   # Directories skipped (up-to-date)
count_overwritten=0               # Directories overwritten/rebuilt
count_errors=0                    # Errors encountered

# === Run ID for audit trail (2.2+) ===
RUN_ID=$(uuidgen 2>/dev/null || date +%s$$)

# === Source libraries ===
CANDIDATES=(
  "$BASE_DIR/lib"
  "/usr/local/share/checksums/lib"
  "/usr/share/checksums/lib"
)

sourced_any=0
for d in "${CANDIDATES[@]}"; do
  if [ -d "$d" ]; then
    for lib in "$d"/*.sh; do
      [ -f "$lib" ] && . "$lib"
    done
    sourced_any=1
    break
  fi
done

if [ "$sourced_any" -eq 0 ]; then
  echo "FATAL: no library files found; expected under one of:" >&2
  printf '  %s\n' "${CANDIDATES[@]}" >&2
  exit 2
fi

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
    local bn sumf
    bn=$(basename "$d")
    # Hidden folders are considered skipped for preview
    case "$bn" in
      .*) printf '%s\0' "$d" >> "$out_skipped"; continue ;;
    esac
    # For quick preview we classify everything as to_process except hidden ones.
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

  : > "$plan_to_process_file"
  : > "$plan_skipped_file"

  # Collect all directories under base (sorted, NUL-delimited)
  while IFS= read -r -d '' d; do
    local base_name sumf metaf
    base_name=$(basename "$d")
    sumf="$d/$MD5_FILENAME"
    metaf="$d/$META_FILENAME"

    # Skip hidden folders
    case "$base_name" in
      .*) printf '%s\0' "$d" >> "$plan_skipped_file"; continue ;;
    esac

    # In verify-only, treat as processed (execution will avoid writes)
    if [ "$VERIFY_ONLY" -eq 1 ]; then
      printf '%s\0' "$d" >> "$plan_to_process_file"
      continue
    fi

    if [ -f "$sumf" ] && [ "$FORCE_REBUILD" -eq 0 ]; then
      # If any file newer than sumfile, we need to process
      if find_file_expr "$d" | LC_ALL=C xargs -0 -n1 -I{} bash -c 'test "{}" -nt "'"$sumf"'" && exit 0' 2>/dev/null; then
        printf '%s\0' "$d" >> "$plan_to_process_file"
        continue
      fi

      local fcount sumlines
      fcount=$(count_files "$d")
      sumlines=$(wc -l <"$sumf" 2>/dev/null || echo 0)
      if [ "$fcount" -ne "$sumlines" ]; then
        printf '%s\0' "$d" >> "$plan_to_process_file"
        continue
      fi

      # Use meta to determine unchanged directories quickly
      if verify_meta_sig "$metaf"; then
        read_meta "$metaf"
        local changed=0
        if [ "$USE_ASSOC" -eq 1 ]; then
          for p in "${!meta_mtime[@]}"; do
            if [ ! -e "$d/$p" ]; then changed=1; break; fi
            if [ "$(stat_field "$d/$p" mtime)" != "${meta_mtime[$p]}" ] || [ "$(stat_field "$d/$p" size)" != "${meta_size[$p]}" ]; then changed=1; break; fi
          done
        else
          while IFS=$'\t' read -r path inode dev mtime size hash; do
            [ -z "$path" ] && continue
            case "$path" in \#meta|\#sig|\#run) continue ;; esac
            if [ ! -e "$d/$path" ]; then changed=1; break; fi
            if [ "$(stat_field "$d/$path" mtime)" != "$mtime" ] || [ "$(stat_field "$d/$path" size)" != "$size" ]; then changed=1; break; fi
          done < "$metaf"
        fi
        if [ "$changed" -eq 0 ]; then
          printf '%s\0' "$d" >> "$plan_skipped_file"
          continue
        fi
      fi

      printf '%s\0' "$d" >> "$plan_to_process_file"
    else
      printf '%s\0' "$d" >> "$plan_to_process_file"
    fi
  done < <(find "$base" -type d -print0 | LC_ALL=C sort -z)
}

# ---------------------------------------------------------------------
# process_single_directory remains unchanged in semantics.
# It performs per-directory hashing, meta writes, and logging.
# ---------------------------------------------------------------------
process_single_directory() {
  local d="$1"
  local sumf="$d/$MD5_FILENAME" metaf="$d/$META_FILENAME" logf="$d/$LOG_FILENAME"

  # Prepare per-directory log: rotate and add audit run header
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
    if [ "$VERIFY_ONLY" -eq 0 ]; then
      rm -f -- "$metaf" 2>/dev/null || record_error "Could not remove invalid meta $metaf"
    fi
  fi

  # Verification-only mode
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
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find_file_expr "$d" | LC_ALL=C sort -z)

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: Would process ${#files[@]} files in $d"
  else
    : > "$tmp_sum" || { record_error "Cannot write $tmp_sum"; return; }
    : > "$tmp_meta" || { record_error "Cannot write $tmp_meta"; return; }
  fi

  # Build old manifest maps and inode-based cache (for hardlinks)
  declare -A old_path_by_inode old_mtime old_size old_hash
  declare -A inode_hash_cache
  local MAP_old_path_by_inode MAP_old_mtime MAP_old_size MAP_old_hash MAP_inode_hash_cache
  if [ "$USE_ASSOC" -eq 0 ]; then
    MAP_old_path_by_inode="$(mktemp)"; : > "$MAP_old_path_by_inode"
    MAP_old_mtime="$(mktemp)"; : > "$MAP_old_mtime"
    MAP_old_size="$(mktemp)"; : > "$MAP_old_size"
    MAP_old_hash="$(mktemp)"; : > "$MAP_old_hash"
    MAP_inode_hash_cache="$(mktemp)"; : > "$MAP_inode_hash_cache"
  fi

  if [ "$USE_ASSOC" -eq 1 ]; then
    for p in "${!meta_inode_dev[@]}"; do
      old_path_by_inode["${meta_inode_dev[$p]}"]="$p"
      old_mtime["$p"]="${meta_mtime[$p]}"
      old_size["$p"]="${meta_size[$p]}"
      old_hash["$p"]="${meta_hash_by_path[$p]}"
      inode_hash_cache["${meta_inode_dev[$p]}"]="${meta_hash_by_path[$p]}"
    done
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

  local results_file=""
  if [ "$DRY_RUN" -eq 0 ]; then
    results_file="$(mktemp "${TMPDIR:-/tmp}/hash_results.XXXXXX")" || results_file="$tmp_sum.hash.results"
    : > "$results_file"
  fi

  declare -A path_to_hash path_to_inode path_to_meta
  local MAP_path_to_hash MAP_path_to_inode MAP_path_to_meta
  if [ "$USE_ASSOC" -eq 0 ]; then
    MAP_path_to_hash="$(mktemp)"; : > "$MAP_path_to_hash"
    MAP_path_to_inode="$(mktemp)"; : > "$MAP_path_to_inode"
    MAP_path_to_meta="$(mktemp)"; : > "$MAP_path_to_meta"
  fi

  for fpath in "${files[@]}"; do
    local fname inode dev mtime size inode_dev reuse h
    fname=$(basename "$fpath")
    inode=$(stat_field "$fpath" inode); dev=$(stat_field "$fpath" dev)
    mtime=$(stat_field "$fpath" mtime); size=$(stat_field "$fpath" size)
    inode_dev="${inode}:${dev}"
    reuse=0; h=""

    if [ "$USE_ASSOC" -eq 1 ]; then
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

    if [ "$reuse" -eq 0 ]; then
      if [ "$USE_ASSOC" -eq 1 ]; then
        if [ -n "${meta_mtime[$fname]:-}" ] && [ "${meta_mtime[$fname]}" = "$mtime" ] && [ "${meta_size[$fname]}" = "$size" ]; then
          h="${meta_hash_by_path[$fname]}"; reuse=1
          inode_hash_cache["$inode_dev"]="$h"
          log "Reusing hash for unchanged file $fname"
        fi
      else
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

    if [ "$USE_ASSOC" -eq 1 ]; then
      path_to_inode["$fpath"]="$inode_dev"
      path_to_meta["$fpath"]="${fname}"$'\t'"${inode}"$'\t'"${dev}"$'\t'"${mtime}"$'\t'"${size}"
    else
      map_set "$MAP_path_to_inode" "$fpath" "$inode_dev"
      map_set "$MAP_path_to_meta" "$fpath" "${fname}"$'\t'"${inode}"$'\t'"${dev}"$'\t'"${mtime}"$'\t'"${size}"
    fi

    if [ "$reuse" -eq 1 ]; then
      if [ "$USE_ASSOC" -eq 1 ]; then
        path_to_hash["$fpath"]="$h"
      else
        map_set "$MAP_path_to_hash" "$fpath" "$h"
      fi
      continue
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRYRUN: would hash $fpath with $PER_FILE_ALGO"
      if [ "$USE_ASSOC" -eq 1 ]; then
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

  if [ "$DRY_RUN" -eq 0 ]; then
    _par_wait_all
    while IFS=$'\t' read -r rpath rhash; do
      if [ "$USE_ASSOC" -eq 1 ]; then
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

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "$USE_ASSOC" -eq 1 ]; then
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
      rm -f "$MAP_path_to_hash" "$MAP_path_to_inode" "$MAP_path_to_meta" 2>/dev/null || true
    fi

    local lockfile="${metaf}${LOCK_SUFFIX}"

    local -a meta_lines=()
    while IFS= read -r line; do
      meta_lines+=("$line")
    done < "$tmp_meta"

    with_lock "$lockfile" write_meta "$metaf" "${meta_lines[@]}"
    mv -f "$tmp_sum" "$sumf" || record_error "Failed to move $tmp_sum -> $sumf"
    log "Wrote $sumf and $metaf"
  fi

  if [ "$USE_ASSOC" -eq 0 ]; then
    rm -f "$MAP_old_path_by_inode" "$MAP_old_mtime" "$MAP_old_size" "$MAP_old_hash" "$MAP_inode_hash_cache" 2>/dev/null || true
  fi

  log "Finished directory: $d"
  LOG_FILEPATH=""
}

# ---------------------------------------------------------------------
# Orchestrator: planning (quick preview), prompt, accurate planning,
# then skip logging and execution. first_run_verify is called after
# confirmation. Any scheduled overwrites from first_run_verify are
# executed by the orchestrator now.
# ---------------------------------------------------------------------
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
    while IFS= read -r -d '' f; do
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
  # Now run first-run verification (if requested) after confirmation
  # first_run_verify will only schedule overwrites in first_run_overwrite
  # -----------------------------------------------------------------
  if [ "$FIRST_RUN" -eq 1 ]; then
    first_run_verify "$TARGET_DIR"
  fi

  # If first_run_verify scheduled overwrites, perform them now (user already confirmed)
  if [ "${#first_run_overwrite[@]}" -gt 0 ]; then
    log "First-run: performing ${#first_run_overwrite[@]} scheduled overwrite(s)"
    for d in "${first_run_overwrite[@]}"; do
      # Safety: only run overwrite if directory still exists
      if [ -d "$d" ]; then
        process_single_directory "$d"
        count_overwritten=$((count_overwritten+1))
        count_processed=$((count_processed+1))
      else
        record_error "First-run scheduled overwrite target missing: $d"
      fi
    done
    # Clear the schedule after execution
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

  # Emit skip logs now (rotation + header) for skipped directories
  for d in "${plan_skipped[@]}"; do
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

main() {
  parse_args "$@"
  run_checksums
}

main "$@"
