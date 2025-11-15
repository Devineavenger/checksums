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
      # If any file newer than sumfile, we need to process
      if find_file_expr "$d" \
         | LC_ALL=C xargs -0 -r -n1 -I{} sh -c "test \"\$1\" -nt \"\$2\"" sh {} "$sumf" 2>/dev/null; then
        reason="newer-file-detected"
        printf '%s\0' "$d" >> "$plan_to_process_file"
        vlog "PLAN: process $d reason=$reason"
        continue
      fi

      local fcount sumlines
      fcount=$(count_files "$d")
      sumlines=$(wc -l <"$sumf" 2>/dev/null || echo 0)
      if [ "$fcount" -ne "$sumlines" ]; then
        reason="filecount-mismatch"
        printf '%s\0' "$d" >> "$plan_to_process_file"
        vlog "PLAN: process $d reason=$reason"
        continue
      fi

      # Use meta to determine unchanged directories quickly
      # Only attempt verify/read when the metafile actually exists and signature verifies
      if [ -f "$metaf" ] && verify_meta_sig "$metaf"; then
        read_meta "$metaf"
        changed=0
        reason="meta-verified"
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

        # Optional: when enabled, run md5 verification for MD5-only dirs and
        # emit concise MISSING / MISMATCH / VERIFIED lines into the run log.
        if [ "${VERIFY_MD5_DETAILS:-0}" -eq 1 ] && [ -f "$sumf" ]; then
          # verify_md5_file writes FIRST_RUN_LOG entries; we prefer to capture
          # the verifier outcome and write compact entries into RUN_LOG.
          # verify_md5_file return codes: 0 ok, 1 mismatch, 2 missing
          local vr
          vr=2
          verify_md5_file "$d" || vr=$?
          case "$vr" in
            0)
              vlog "MD5-DETAIL: verified OK for $d"
              [ -n "${RUN_LOG:-}" ] && printf 'VERIFIED: %s\n' "$d" >>"${RUN_LOG}"
              ;;
            1)
              log "MD5-DETAIL: mismatches in $d"
              # For compactness we record the directory; details remain in FIRST_RUN_LOG if available
              [ -n "${RUN_LOG:-}" ] && printf 'MISMATCH: %s\n' "$d" >>"${RUN_LOG}"
              ;;
            2)
              log "MD5-DETAIL: missing files referenced in $d"
              [ -n "${RUN_LOG:-}" ] && printf 'MISSING: %s\n' "$d" >>"${RUN_LOG}"
              ;;
            *)
              log "MD5-DETAIL: verifier returned $vr for $d"
              ;;
          esac
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