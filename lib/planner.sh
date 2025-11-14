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

    # Optional: align preview with SKIP_EMPTY behavior using a cheap shallow test
    if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "$FORCE_REBUILD" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
      # Cheap shallow check for any regular file in the directory (fast preview)
      if ! find "$d" -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
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

    # When NO_ROOT_SIDEFILES is set, never schedule the base directory itself
    if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ "$d" = "$base" ]; then
      printf '%s\0' "$d" >> "$plan_skipped_file"
      continue
    fi

    # In verify-only, treat as processed (execution will avoid writes)
    if [ "$VERIFY_ONLY" -eq 1 ]; then
      printf '%s\0' "$d" >> "$plan_to_process_file"
      continue
    fi

    # First-run carve-out: If we are in FIRST_RUN and the directory has .md5
    # but is missing .meta or .log, schedule processing even if no user files exist.
    if [ "${FIRST_RUN:-0}" -eq 1 ]; then
      if [ -f "$sumf" ] && { [ ! -f "$metaf" ] || [ ! -f "$d/$LOG_FILENAME" ]; }; then
        printf '%s\0' "$d" >> "$plan_to_process_file"
        continue
      fi
    fi

    # If SKIP_EMPTY is enabled, quickly check for any regular files anywhere under d.
    # This avoids scheduling directories that contain only subdirectories (no files)
    # and prevents creation of .meta/.log/.md5 sidecar files for those folders.
    if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "$FORCE_REBUILD" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
      if ! has_files "$d"; then
        printf '%s\0' "$d" >> "$plan_skipped_file"
        continue
      fi
    fi

    if [ -f "$sumf" ] && [ "$FORCE_REBUILD" -eq 0 ]; then
      # If any file newer than sumfile, we need to process
      if find_file_expr "$d" | LC_ALL=C xargs -0 -n1 -I{} bash -c "test \"\$1\" -nt \"\$2\"" _ {} "$sumf" 2>/dev/null; then
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
        if [ "${USE_ASSOC:-0}" -eq 1 ]; then
          # shellcheck disable=SC2154  # meta_mtime/meta_size defined in init.sh and populated by read_meta
          if [ "${#meta_mtime[@]}" -gt 0 ]; then
            for p in "${!meta_mtime[@]}"; do
              if [ ! -e "$d/$p" ]; then changed=1; break; fi
              if [ "$(stat_field "$d/$p" mtime)" != "${meta_mtime[$p]:-}" ] || [ "$(stat_field "$d/$p" size)" != "${meta_size[$p]:-}" ]; then changed=1; break; fi
            done
          fi
        else
          # legacy meta format: path<TAB>inode<TAB>dev<TAB>mtime<TAB>size<TAB>hash
          while IFS=$'\t' read -r path _inode _dev mtime size _hash; do
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
