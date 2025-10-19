#!/usr/bin/env bash
# first_run.sh
#
# First-run verification logic and md5 verification helper.
# Unmodified behavior relative to 2.2, except counters and verify-only awareness remain.

verify_md5_file() {
  local dir="$1"
  local sumf="$dir/$MD5_FILENAME"
  [ -f "$sumf" ] || return 2
  dbg "Verifying $sumf"

  if command -v md5sum >/dev/null 2>&1; then
    # Try GNU md5sum check first
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
      *)        # Assume GNU format: hash␣␣filename
        expected=$(printf '%s' "$entry" | awk '{print $1}')
        fname=$(printf '%s' "$entry" | awk '{$1=""; sub(/^ +/,""); print}')
        ;;
    esac

    local fpath="$dir/$fname"
    if [ ! -e "$fpath" ]; then
      missing=1
      [ -n "$FIRST_RUN_LOG" ] && printf 'MISSING: %s\n' "$fpath" >> "$FIRST_RUN_LOG"
      continue
    fi

    actual=$(file_hash "$fpath" "md5")
    if [ "$actual" != "$expected" ]; then
      bad=1
      [ -n "$FIRST_RUN_LOG" ] && \
        printf 'MISMATCH %s: expected %s actual %s\n' "$fname" "$expected" "$actual" >> "$FIRST_RUN_LOG"
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

first_run_verify() {
  local base="$1"
  local -a targets=()

  while IFS= read -r -d '' f; do
    local d; d=$(dirname "$f")
    [ ! -f "$d/$META_FILENAME" ] && [ ! -f "$d/$LOG_FILENAME" ] && targets+=("$d")
  done < <(find "$base" -type f -name "$MD5_FILENAME" -print0 | LC_ALL=C sort -z)

  if [ "${#targets[@]}" -eq 0 ]; then
    log "First-run: no existing $MD5_FILENAME needing verification found."
    return 0
  fi

  FIRST_RUN_LOG="${TARGET_DIR%/}/first_run.log"
  : > "$FIRST_RUN_LOG"
  log "First-run: found ${#targets[@]} directories; detailed first-run log: $FIRST_RUN_LOG"
  first_run_log "First-run start: base=$base  files: ${#targets[@]}"

  for d in "${targets[@]}"; do
    first_run_log "Verifying directory: $d"
    log "Verifying existing checksums in: $d"
    if verify_md5_file "$d"; then
      first_run_log "Verified OK: $d"
      log "Verified OK: $d"
      count_verified=$((count_verified+1))
      # On success, create meta/log using normal processing (unless dry-run or verify-only)
      if [ "$DRY_RUN" -eq 1 ] || [ "$VERIFY_ONLY" -eq 1 ]; then
        first_run_log "DRY/VERIFY: meta/log creation suppressed for $d"
      else
        process_single_directory "$d"
      fi
      continue
    fi

    # mismatch detected
    first_run_log "Verification FAILED for $d"
    log "Verification FAILED for $d"

    # If FIRST_RUN_CHOICE non-interactive, obey it
    case "$FIRST_RUN_CHOICE" in
      skip)
        first_run_log "CHOICE skip: recorded mismatch for $d"
        record_error "First-run: skipped $d due to checksum mismatch"
        continue
        ;;
      overwrite)
        # In verify-only mode, we cannot overwrite; record the intent but skip the write.
        if [ "$VERIFY_ONLY" -eq 1 ]; then
          first_run_log "CHOICE overwrite suppressed in verify-only for $d"
          record_error "First-run: overwrite requested but skipped (verify-only) for $d"
          continue
        fi
        first_run_log "CHOICE overwrite: recomputing checksums for $d"
        log "Auto-overwrite: recomputing for $d"
        if [ "$DRY_RUN" -eq 1 ]; then
          first_run_log "DRYRUN: would overwrite $d/$MD5_FILENAME"
          log "DRYRUN: would overwrite $d/$MD5_FILENAME"
        else
          process_single_directory "$d"
          first_run_log "OVERWRITE completed for $d"
          count_overwritten=$((count_overwritten+1))
        fi
        continue
        ;;
      prompt)
        while true; do
          printf 'Directory %s has mismatched checksums. Choose action: [s]kip, [o]verwrite, [a]bort: ' "$d"
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
              first_run_log "CHOICE overwrite for $d"
              if [ "$DRY_RUN" -eq 1 ]; then
                first_run_log "DRYRUN: would overwrite $d/$MD5_FILENAME"
              else
                process_single_directory "$d"
                first_run_log "OVERWRITE completed for $d"
                count_overwritten=$((count_overwritten+1))
              fi
              break
              ;;
            a|A)
              first_run_log "CHOICE abort at $d"
              log "User aborted at first-run mismatch in $d"
              exit 2
              ;;
            *) printf 'Please enter s, o, or a\n' ;;
          esac
        done
        ;;
      *)
        first_run_log "Unknown FIRST_RUN_CHOICE='$FIRST_RUN_CHOICE'; treating as skip for $d"
        record_error "First-run: unknown choice for $d; skipped"
        ;;
    esac
  done

  first_run_log "First-run completed."
  return 0
}
