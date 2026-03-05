#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# shellcheck disable=SC2034,SC2154

# status.sh
#
# Status/diff mode: show what has changed since the last manifest.
#
# Responsibilities:
#  - status_single_directory(): classify every file in one directory as NEW,
#    DELETED, MODIFIED, or UNCHANGED relative to the stored .md5/.meta manifest.
#  - run_status(): top-level orchestrator for status mode.
#  - Uses shared color palette from color.sh (_C_GREEN, _C_RED, _C_YELLOW, etc.).

# === Per-directory result accumulators (Bash 3.2 safe — no namerefs) ===

_STATUS_DIR_NEW=()
_STATUS_DIR_DEL=()
_STATUS_DIR_MOD=()
_STATUS_DIR_UNCH=()

# === Core: classify files in a single directory ===

# status_single_directory DIR
#
# Classify files in DIR against the existing manifest.
# Populates _STATUS_DIR_NEW, _STATUS_DIR_DEL, _STATUS_DIR_MOD, _STATUS_DIR_UNCH.
#
# Returns:
#   0  no changes (all UNCHANGED)
#   1  at least one NEW/DELETED/MODIFIED
#   2  no manifest (untracked directory)
#
status_single_directory() {
  local d="$1"
  local sumf="$d/$SUM_FILENAME"
  local metaf="$d/$META_FILENAME"

  _STATUS_DIR_NEW=()
  _STATUS_DIR_DEL=()
  _STATUS_DIR_MOD=()
  _STATUS_DIR_UNCH=()

  # No manifest at all → untracked
  [ -f "$sumf" ] || return 2

  # Check meta availability and validity
  local have_meta=0
  if [ -f "$metaf" ] && verify_meta_sig "$metaf" 2>/dev/null; then
    read_meta "$metaf"
    have_meta=1
  fi

  # Build manifest-known set from .md5
  local -a manifest_names=()
  local -a manifest_hashes=()
  local entry fname expected
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -z "$entry" ] && continue
    case "$entry" in \#*) continue ;; esac
    case "$entry" in
      MD5*=*)
        fname=$(printf '%s' "$entry" | sed -E 's/^MD5 \((.*)\) = .*/\1/')
        expected=$(printf '%s' "$entry" | awk '{print $NF}')
        ;;
      *)
        expected=${entry%%[[:space:]]*}
        fname=${entry#"$expected"}
        fname=$(printf '%s' "$fname" | sed -E 's/^[[:space:]]+[*[:space:]]*//')
        ;;
    esac
    fname="${fname#./}"
    [ -z "$fname" ] && continue
    manifest_names+=("$fname")
    manifest_hashes+=("$expected")
  done < "$sumf"

  # Build disk-current set via find_file_expr (respects INCLUDE/EXCLUDE)
  local -a disk_names=()
  local f
  while IFS= read -r -d '' f; do
    disk_names+=("$(basename "$f")")
  done < <(find_file_expr "$d")

  # Pass 1: classify each manifest entry
  local idx=0
  for fname in "${manifest_names[@]}"; do
    if [ ! -e "$d/$fname" ]; then
      _STATUS_DIR_DEL+=("$fname")
      idx=$((idx+1))
      continue
    fi

    local classified=0

    # Fast path: meta with stat comparison (Bash 4+ assoc arrays)
    if [ "$have_meta" -eq 1 ] && [ "${USE_ASSOC:-0}" -eq 1 ]; then
      if [ -n "${meta_mtime[$fname]+x}" ]; then
        local _sl _si _sd _sm _ss
        _sl="$(stat_all_fields "$d/$fname" 2>/dev/null)" || _sl=""
        IFS=$'\t' read -r _si _sd _sm _ss <<< "$_sl"
        if [ "${_sm:-0}" = "${meta_mtime[$fname]:-}" ] \
           && [ "${_ss:-0}" = "${meta_size[$fname]:-}" ] \
           && [ "${_si:-0}:${_sd:-0}" = "${meta_inode_dev[$fname]:-}" ]; then
          _STATUS_DIR_UNCH+=("$fname")
          classified=1
        else
          # Stat differs — modified (or rehash with -R to confirm)
          if [ "${NO_REUSE:-0}" -eq 1 ]; then
            local rehash
            rehash=$(file_hash "$d/$fname" "$PER_FILE_ALGO")
            if [ "$rehash" = "${meta_hash_by_path[$fname]:-}" ]; then
              _STATUS_DIR_UNCH+=("$fname")
            else
              _STATUS_DIR_MOD+=("$fname")
            fi
          else
            _STATUS_DIR_MOD+=("$fname")
          fi
          classified=1
        fi
      fi
    fi

    # Fallback: meta with text parsing (Bash 3.2 or assoc miss)
    if [ "$classified" -eq 0 ] && [ "$have_meta" -eq 1 ] && [ "${USE_ASSOC:-0}" -eq 0 ]; then
      local _found=0
      while IFS=$'\t' read -r _path _inode _dev _mtime _size _hash; do
        [ -z "$_path" ] && continue
        case "$_path" in \#meta|\#sig|\#run) continue ;; esac
        [ "$_path" != "$fname" ] && continue
        _found=1
        local _sl _si _sd _sm _ss
        _sl="$(stat_all_fields "$d/$fname" 2>/dev/null)" || _sl=""
        IFS=$'\t' read -r _si _sd _sm _ss <<< "$_sl"
        if [ "${_sm:-0}" = "$_mtime" ] \
           && [ "${_ss:-0}" = "$_size" ] \
           && [ "${_si:-0}:${_sd:-0}" = "${_inode:-0}:${_dev:-0}" ]; then
          _STATUS_DIR_UNCH+=("$fname")
        else
          if [ "${NO_REUSE:-0}" -eq 1 ]; then
            local rehash
            rehash=$(file_hash "$d/$fname" "$PER_FILE_ALGO")
            if [ "$rehash" = "$_hash" ]; then
              _STATUS_DIR_UNCH+=("$fname")
            else
              _STATUS_DIR_MOD+=("$fname")
            fi
          else
            _STATUS_DIR_MOD+=("$fname")
          fi
        fi
        break
      done < "$metaf"
      [ "$_found" -eq 1 ] && classified=1
    fi

    # No meta: use .md5 hash comparison with -R, otherwise assume unchanged
    if [ "$classified" -eq 0 ]; then
      if [ "${NO_REUSE:-0}" -eq 1 ]; then
        local rehash
        rehash=$(file_hash "$d/$fname" "$PER_FILE_ALGO")
        if [ "$rehash" = "${manifest_hashes[$idx]}" ]; then
          _STATUS_DIR_UNCH+=("$fname")
        else
          _STATUS_DIR_MOD+=("$fname")
        fi
      else
        _STATUS_DIR_UNCH+=("$fname")
      fi
    fi

    idx=$((idx+1))
  done

  # Pass 2: find new files (on disk but not in manifest)
  local dname
  for dname in "${disk_names[@]}"; do
    local in_manifest=0 mname
    for mname in "${manifest_names[@]}"; do
      if [ "$dname" = "$mname" ]; then in_manifest=1; break; fi
    done
    [ "$in_manifest" -eq 0 ] && _STATUS_DIR_NEW+=("$dname")
  done

  # Clear STAT_CACHE to prevent unbounded growth
  if [ "${USE_ASSOC:-0}" -eq 1 ]; then
    STAT_CACHE=()
  fi

  # Return: 0 = clean, 1 = changes
  [ "${#_STATUS_DIR_NEW[@]}" -eq 0 ] \
    && [ "${#_STATUS_DIR_DEL[@]}" -eq 0 ] \
    && [ "${#_STATUS_DIR_MOD[@]}" -eq 0 ] \
    && return 0 || return 1
}

# === Output helpers ===

_status_print_directory() {
  local d="$1" has_changes="$2"
  local rel
  rel="${d#"$TARGET_DIR"}"
  [ -z "$rel" ] && rel="/"
  rel="${rel#/}"
  [ -z "$rel" ] && rel="."

  if [ "$has_changes" -eq 1 ]; then
    printf "${_C_BOLD}%s/${_C_RST}\n" "$rel"
    local f
    for f in "${_STATUS_DIR_NEW[@]}"; do
      printf "  ${_C_GREEN}A${_C_RST}  %s\n" "$f"
    done
    for f in "${_STATUS_DIR_DEL[@]}"; do
      printf "  ${_C_RED}D${_C_RST}  %s\n" "$f"
    done
    for f in "${_STATUS_DIR_MOD[@]}"; do
      printf "  ${_C_YELLOW}M${_C_RST}  %s\n" "$f"
    done
    if [ "${VERBOSE:-0}" -gt 0 ]; then
      for f in "${_STATUS_DIR_UNCH[@]}"; do
        printf "     %s\n" "$f"
      done
    fi
    printf '\n'
  elif [ "${VERBOSE:-0}" -gt 0 ]; then
    printf "%s/  (%d files, up-to-date)\n" "$rel" "${#_STATUS_DIR_UNCH[@]}"
  fi
}

_status_print_untracked() {
  local d="$1"
  local rel
  rel="${d#"$TARGET_DIR"}"
  rel="${rel#/}"
  [ -z "$rel" ] && rel="."
  printf "  ${_C_YELLOW}?${_C_RST}  %s/\n" "$rel"
}

_status_print_summary() {
  local dirs="$1" new="$2" del="$3" mod="$4" unch="$5" untracked="$6"
  local dword
  [ "$dirs" -eq 1 ] && dword="directory" || dword="directories"
  printf "Summary: %d %s checked" "$dirs" "$dword"
  [ "$new" -gt 0 ] && printf ", ${_C_GREEN}%d new${_C_RST}" "$new"
  [ "$del" -gt 0 ] && printf ", ${_C_RED}%d deleted${_C_RST}" "$del"
  [ "$mod" -gt 0 ] && printf ", ${_C_YELLOW}%d modified${_C_RST}" "$mod"
  printf ", %d unchanged" "$unch"
  [ "$untracked" -gt 0 ] && printf ", %d untracked" "$untracked"
  printf '\n'
}

# === Top-level status orchestrator ===

run_status() {
  trap '_orch_cleanup' EXIT
  trap '_orch_cleanup; exit 130' INT
  trap '_orch_cleanup; exit 143' TERM

  if [ "$DEBUG" -gt 0 ]; then log_level=3
  elif [ "$VERBOSE" -ge 2 ]; then log_level=3
  elif [ "$VERBOSE" -gt 0 ]; then log_level=2
  fi

  if [ "${QUIET:-0}" -eq 1 ]; then
    log_level=0
    PROGRESS=0
  fi

  detect_tools
  detect_stat
  check_bash_version

  if ! check_required_tools; then fatal "Missing tools; see output for hints."; fi

  cd "$TARGET_DIR" || fatal "Cannot cd to $TARGET_DIR"
  TARGET_DIR=$(pwd -P)
  cd - >/dev/null 2>&1 || true

  if [ "$TARGET_DIR" = "/" ]; then
    fatal "Refusing to run on system root"
  fi

  # Status mode does not write a run log
  RUN_LOG=""
  LOG_FILEPATH=""

  build_exclusions

  local st_new=0 st_del=0 st_mod=0 st_unch=0 st_untracked=0 st_dirs=0
  local any_changes=0
  local has_untracked=0

  local -a untracked_dirs=()

  while IFS= read -r -d '' d; do
    local base_name
    base_name=$(basename "$d")

    # Skip hidden directories
    case "$base_name" in .*) continue ;; esac

    # Respect NO_ROOT_SIDEFILES
    if [ "${NO_ROOT_SIDEFILES:-0}" -eq 1 ] && [ "$d" = "$TARGET_DIR" ]; then
      continue
    fi

    # Respect SKIP_EMPTY — but still check directories that have manifests
    # (a dir with all files deleted still has sidecars we need to diff against)
    if [ "${SKIP_EMPTY:-1}" -eq 1 ] && ! has_local_files "$d"; then
      [ -f "$d/$SUM_FILENAME" ] || continue
    fi

    st_dirs=$((st_dirs + 1))

    local dir_rc=0
    status_single_directory "$d" || dir_rc=$?

    if [ "$dir_rc" -eq 2 ]; then
      st_untracked=$((st_untracked + 1))
      any_changes=1
      has_untracked=1
      untracked_dirs+=("$d")
      continue
    fi

    st_new=$((st_new + ${#_STATUS_DIR_NEW[@]}))
    st_del=$((st_del + ${#_STATUS_DIR_DEL[@]}))
    st_mod=$((st_mod + ${#_STATUS_DIR_MOD[@]}))
    st_unch=$((st_unch + ${#_STATUS_DIR_UNCH[@]}))

    local dir_has_changes=0
    if [ "${#_STATUS_DIR_NEW[@]}" -gt 0 ] || [ "${#_STATUS_DIR_DEL[@]}" -gt 0 ] || [ "${#_STATUS_DIR_MOD[@]}" -gt 0 ]; then
      dir_has_changes=1
      any_changes=1
    fi

    _status_print_directory "$d" "$dir_has_changes"

  done < <(find "$TARGET_DIR" -type d -print0 | LC_ALL=C sort -z)

  # Print untracked directories section
  if [ "$has_untracked" -eq 1 ]; then
    printf "\nUntracked directories (no manifest):\n"
    local ud
    for ud in "${untracked_dirs[@]}"; do
      _status_print_untracked "$ud"
    done
    printf '\n'
  fi

  _status_print_summary "$st_dirs" "$st_new" "$st_del" "$st_mod" "$st_unch" "$st_untracked"

  [ "$any_changes" -eq 0 ] && return 0 || return 1
}
