#!/usr/bin/env bash
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
  local sumf="$dir/$MD5_FILENAME"
  [ -f "$sumf" ] || return 2
  vlog "Verifying $sumf"

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
      continue
    fi

    actual=$(file_hash "$fpath" "md5")
    if [ "$actual" != "$expected" ]; then
      bad=1
      [ -n "$FIRST_RUN_LOG" ] && \
        printf 'MISMATCH: %s\texpected=%s\tactual=%s\n' "$fpath" "$expected" "$actual" >> "$FIRST_RUN_LOG"
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

  # Collect directories that contain an .md5 and have at least one sidefile missing.
  # Bash 3.x lacks associative arrays; guard declare -A and provide a simple fallback.
  if declare -p -A >/dev/null 2>&1; then
    # Bash ≥ 4: use an assoc set to avoid duplicate targets.
    declare -A _fr_seen=()
    while IFS= read -r -d '' f; do
      local d; d=$(dirname "$f")
      # Select if either .meta OR .log is missing
      if [ ! -f "$d/$META_FILENAME" ] || [ ! -f "$d/$LOG_FILENAME" ]; then
        if [ -z "${_fr_seen[$d]:-}" ]; then
          targets+=("$d")
          _fr_seen["$d"]=1
        fi
      fi
    done < <(find "$base" -type f -name "$MD5_FILENAME" -print0 | LC_ALL=C sort -z)
  else
    # Bash < 4: use a space-delimited “seen_list” to prevent duplicates.
    local seen_list=""
    while IFS= read -r -d '' f; do
      local d; d=$(dirname "$f")
      if [ ! -f "$d/$META_FILENAME" ] || [ ! -f "$d/$LOG_FILENAME" ]; then
        case " $seen_list " in
          *" $d "*) ;;               # already present
          *) targets+=("$d"); seen_list="$seen_list $d" ;;
        esac
      fi
    done < <(find "$base" -type f -name "$MD5_FILENAME" -print0 | LC_ALL=C sort -z)
  fi

  if [ "${#targets[@]}" -eq 0 ]; then
    log "First-run: no existing $MD5_FILENAME needing verification found."
    return 0
  fi

  FIRST_RUN_LOG="${TARGET_DIR%/}/${LOG_BASE:-$BASE_NAME}.first-run.log"
  : > "$FIRST_RUN_LOG"
  log "First-run: found ${#targets[@]} directories; detailed first-run log: $FIRST_RUN_LOG"
  first_run_log "First-run start: base=$base  files: ${#targets[@]}"

  for d in "${targets[@]}"; do
    first_run_log "Verifying directory: $d"
    dir_log_append "$d" "Verifying existing checksums in: $d"
    if verify_md5_file "$d"; then
      first_run_log "Verified OK: $d"
      dir_log_append "$d" "Verified OK: $d"
      count_verified=$((count_verified+1))

      # Single, definitive scheduling rule:
      # - Only schedule if the directory contains user files.
      # - In dry-run or verify-only, do not mutate; just log.
      if has_files "$d"; then
        if [ "$DRY_RUN" -eq 1 ] || [ "$VERIFY_ONLY" -eq 1 ]; then
          first_run_log "DRY/VERIFY: meta/log creation suppressed for $d"
        else
          first_run_log "SCHEDULED: would create meta/log for $d"
          first_run_overwrite+=("$d")
          dir_log_append "$d" "SCHEDULED OVERWRITE by first-run"
        fi
      else
        first_run_log "SKIPPED scheduling for empty/container-only directory: $d"
        dir_log_append "$d" "SKIPPED scheduling (no user files)"
      fi
      continue
    fi

    # mismatch detected
    first_run_log "Verification FAILED for $d"
    dir_log_append "$d" "Verification FAILED for $d"

    case "$FIRST_RUN_CHOICE" in
      skip)
        first_run_log "CHOICE skip: recorded mismatch for $d"
        record_error "First-run: skipped $d due to checksum mismatch"
        continue
        ;;
      overwrite)
        if [ "$VERIFY_ONLY" -eq 1 ]; then
          first_run_log "CHOICE overwrite suppressed in verify-only for $d"
          record_error "First-run: overwrite requested but skipped (verify-only) for $d"
          continue
        fi

        # Respect SKIP_EMPTY before scheduling overwrite
        if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "${FORCE_REBUILD:-0}" -eq 0 ] && [ "${VERIFY_ONLY:-0}" -eq 0 ]; then
          if ! has_files "$d"; then
            first_run_log "SKIPPED scheduling overwrite for empty directory: $d"
            dir_log_append "$d" "SKIPPED scheduling overwrite (no user files)"
            count_overwritten=$((count_overwritten+0))
            continue
          fi
        fi

        first_run_log "CHOICE overwrite: scheduling recomputation for $d"
        dir_log_append "$d" "Scheduled auto-overwrite: recomputing for $d"
        if [ "$DRY_RUN" -eq 1 ]; then
          first_run_log "DRYRUN: would overwrite $d/$MD5_FILENAME"
          log "DRYRUN: would overwrite $d/$MD5_FILENAME"
        else
          first_run_overwrite+=("$d")
          first_run_log "SCHEDULED OVERWRITE for $d"
          dir_log_append "$d" "SCHEDULED OVERWRITE by first-run"
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

              # Respect SKIP_EMPTY before scheduling overwrite in interactive prompt
              if [ "${SKIP_EMPTY:-1}" -eq 1 ] && [ "${FORCE_REBUILD:-0}" -eq 0 ] && [ "${VERIFY_ONLY:-0}" -eq 0 ]; then
                if ! has_files "$d"; then
                  first_run_log "SKIPPED scheduling overwrite for empty directory (prompt): $d"
                  dir_log_append "$d" "SKIPPED scheduling overwrite (no user files)"
                  break
                fi
              fi

              first_run_log "CHOICE overwrite for $d"
              if [ "$DRY_RUN" -eq 1 ]; then
                first_run_log "DRYRUN: would overwrite $d/$MD5_FILENAME"
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
