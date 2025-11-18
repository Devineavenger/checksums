#!/usr/bin/env bash
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

  # Collect all directories under base (sorted, NUL-delimited)
  while IFS= read -r -d '' d; do
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
      .*) reason="hidden"; printf '%s\0' "$d" >> "$plan_skipped_file"; vlog "PLAN: skip $d reason=$reason"; continue ;;
    esac

    # When NO_ROOT_SIDEFILES is set, never schedule the base directory itself
    if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ "$d" = "$base" ]; then
      reason="root-protected"
      printf '%s\0' "$d" >> "$plan_skipped_file"
      vlog "PLAN: skip $d reason=$reason"
      continue
    fi

    # In verify-only, treat as processed (execution will avoid writes)
    if [ "$VERIFY_ONLY" -eq 1 ]; then
      reason="verify-only"
      printf '%s\0' "$d" >> "$plan_to_process_file"
      vlog "PLAN: process $d reason=$reason"
      continue
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
        continue
      fi
    fi

    # Always skip directories with no user files when SKIP_EMPTY=1
    if [ "${SKIP_EMPTY:-1}" -eq 1 ] && ! has_files "$d"; then
      reason="no-user-files"
      printf '%s\0' "$d" >> "$plan_skipped_file"
      vlog "PLAN: skip $d reason=$reason"
      continue
    fi

    if [ -f "$sumf" ] && [ "$FORCE_REBUILD" -eq 0 ]; then
      # If any file newer than sumfile, we need to process.
      # Optimization + portability: Use find -newer to short-circuit without spawning many shells.
      # The candidate set is restricted by find_file_expr exclusions; reuse those filters here.
      # Note: find_file_expr emits only direct files (maxdepth 1) and excludes artifacts.
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
        # Use a consistent default for md5-details (enabled unless explicitly disabled).
        local md5_details="${VERIFY_MD5_DETAILS:-1}"
        if [ "$md5_details" -eq 1 ] && [ -f "$sumf" ]; then
          local vr
          vr=$(emit_md5_file_details "$d" "$sumf"; printf '%s' "$?")
          emit_md5_detail "$d" "$vr"
        fi
        continue
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
        continue
      fi

      # Use meta to determine unchanged directories quickly
      # Only attempt verify/read when the metafile actually exists and signature verifies
      if [ -f "$metaf" ] && verify_meta_sig "$metaf"; then
        read_meta "$metaf"
        changed=0
        reason="meta-verified"
        # If enabled, run md5 verification even when meta verifies.
        # This detects hash mismatches / missing files the meta-stat check cannot.
        local md5_details="${VERIFY_MD5_DETAILS:-1}"
        if [ "$md5_details" -eq 1 ] && [ -f "$sumf" ]; then
          # Use the deterministic reporter that parses the .md5 and writes per-file
          # MISSING/MISMATCH lines directly to RUN_LOG. This avoids global FIRST_RUN_LOG
          # aliasing and reproduces the detailed first-run output during planning.
          # Capture the exact return code from emit_md5_file_details reliably.
          # Previous form relied on `|| vr=$?` while vr was preset to 2 which
          # left vr unchanged on success and produced spurious "missing"
          # summaries (directories referenced instead of per-file entries).
          local vr
          vr=$(emit_md5_file_details "$d" "$sumf"; printf '%s' "$?")
          emit_md5_detail "$d" "$vr"
        fi
        if [ "${USE_ASSOC:-0}" -eq 1 ]; then
          # shellcheck disable=SC2154  # meta_mtime/meta_size defined in init.sh and populated by read_meta
          if [ "${#meta_mtime[@]}" -gt 0 ]; then
            for p in "${!meta_mtime[@]}"; do
              if [ ! -e "$d/$p" ]; then changed=1; reason="meta-missing-path"; break; fi
              if [ "$(stat_field "$d/$p" mtime)" != "${meta_mtime[$p]:-}" ] || [ "$(stat_field "$d/$p" size)" != "${meta_size[$p]:-}" ]; then changed=1; reason="meta-stat-changed"; break; fi
            done
          fi
        else
          # legacy meta format: path<TAB>inode<TAB>dev<TAB>mtime<TAB>size<TAB>hash
          while IFS=$'\t' read -r path _inode _dev mtime size _hash; do
            [ -z "$path" ] && continue
            case "$path" in \#meta|\#sig|\#run) continue ;; esac
            if [ ! -e "$d/$path" ]; then changed=1; reason="meta-missing-path"; break; fi
            if [ "$(stat_field "$d/$path" mtime)" != "$mtime" ] || [ "$(stat_field "$d/$path" size)" != "$size" ]; then changed=1; reason="meta-stat-changed"; break; fi
          done < "$metaf"
        fi

        if [ "$changed" -eq 0 ]; then
          printf '%s\0' "$d" >> "$plan_skipped_file"
          vlog "PLAN: skip $d reason=$reason"
          continue
        fi
      else
        # metafile absent or signature invalid: mark as needing processing but log reason
        if [ ! -f "$metaf" ]; then
          reason="meta-missing"
        else
          reason="meta-invalid"
        fi
        # When enabled, always run md5 verification for directories that have a .md5
        # but lack a valid meta (metafile missing or signature invalid). This runs
        # regardless of FIRST_RUN so operators see MISSING/MISMATCH/VERIFIED lines
        # in the run-level log for diagnostic purposes.
        local md5_details="${VERIFY_MD5_DETAILS:-1}"
        if [ "$md5_details" -eq 1 ] && [ -f "$sumf" ]; then
          # As above: deterministic per-file reporting into RUN_LOG for dirs lacking valid meta.
          # Capture the verifier exit code reliably (avoid `cmd || rc=$?` races).
          local vr
          vr=$(emit_md5_file_details "$d" "$sumf"; printf '%s' "$?")
          emit_md5_detail "$d" "$vr"
        fi
        # proceed to schedule for processing below
      fi

      reason="${reason:-needs-recompute}"
      printf '%s\0' "$d" >> "$plan_to_process_file"
      vlog "PLAN: process $d reason=$reason"
    else
      reason="no-sumfile"
      printf '%s\0' "$d" >> "$plan_to_process_file"
      vlog "PLAN: process $d reason=$reason"
    fi
  done < <(find "$base" -type d -print0 | LC_ALL=C sort -z)
}