#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# shellcheck disable=SC2059,SC2034

# menu.sh
#
# Interactive guided command builder for the checksums CLI.
#
# Walks users through all options in 5 compact screens, enforces mutual
# exclusivity, and produces a valid command for copy/paste or immediate
# execution.  Uses simple numbered menus, y/n toggles, and free-text
# input — no curses, tput, or dialog dependency.
#
# Loaded alphabetically between meta.sh and orchestrator.sh by loader.sh.
# Depends on: color.sh (_C_* variables), logging.sh (fatal, log).

# ---------------------------------------------------------------------------
# Navigation constants: screen functions return these to control flow
# ---------------------------------------------------------------------------
readonly _MENU_NEXT=0   # proceed to next screen
readonly _MENU_BACK=1   # go back one screen
readonly _MENU_ABORT=2  # abort the menu entirely

# ---------------------------------------------------------------------------
# Collected state — populated by screen functions, consumed by _menu_build_command.
# Prefixed _m_ to avoid collision with globals.
# ---------------------------------------------------------------------------
_m_mode=""              # generate | verify | status | check
_m_target=""            # target directory path
_m_check_file=""        # manifest file for check mode
_m_algo=""              # per-file algorithm (single or comma-separated)
_m_meta_sig=""          # meta signature algorithm
_m_exclude=""           # exclude patterns (comma-separated)
_m_include=""           # include patterns (comma-separated)
_m_max_size=""          # max file size filter
_m_min_size=""          # min file size filter
_m_follow_symlinks=""   # y or n
_m_parallel=""          # parallel hashing jobs
_m_parallel_dirs=""     # parallel directory processing
_m_batch=""             # batch rules
_m_base_name=""         # sidecar base name
_m_log_base=""          # log base name
_m_store_dir=""         # central manifest store
_m_minimal=""           # y or n
_m_dry_run=""           # y or n
_m_force_rebuild=""     # y or n
_m_assume_yes=""        # y or n
_m_log_format=""        # text | json | csv
_m_verbose=""           # y or n
_m_quiet=""             # y or n
_m_progress=""          # y or n (inverted: n means --no-progress)
_m_no_reuse=""          # y or n — force rehash all files
_m_debug=""             # y or n — debug verbosity
_m_md5_details=""       # y or n — MD5 verification details in planning
_m_skip_empty=""        # y or n — skip empty directories
_m_allow_root=""        # y or n — allow sidecar files in root directory
_m_first_run=""         # y or n
_m_first_run_choice=""  # skip | overwrite | prompt
_m_first_run_keep=""    # y or n

# Built command state — populated by _menu_build_command
_menu_args=()           # argument array for in-process execution
_menu_cmd_str=""        # display string for copy/paste

# ---------------------------------------------------------------------------
# UI Primitives
# ---------------------------------------------------------------------------

# _menu_header TITLE — print a bold section header with a separator line.
# Output goes to stderr so it is visible even inside $() command substitution.
_menu_header() {
  printf '\n%b─── %s ───%b\n' "${_C_BOLD}" "$1" "${_C_RST}" >&2
}

# _menu_skip_note REASON — print a dim note for skipped/incompatible options.
# Output goes to stderr so it is visible even inside $() command substitution.
_menu_skip_note() {
  printf '  %b(%s)%b\n' "${_C_DIM}" "$1" "${_C_RST}" >&2
}

# _menu_prompt PROMPT DEFAULT — read a line from stdin.
#
# Displays PROMPT with [DEFAULT] hint on stderr, reads one line from stdin.
# Return codes communicate navigation decisions (globals don't propagate
# out of $() subshells, so we use distinct exit codes instead):
#   0        → value on stdout (either DEFAULT or user input)
#   1 (BACK) → user typed 'b'
#   2 (ABORT)→ user typed 'q' or EOF on stdin
_menu_prompt() {
  local prompt="$1" default="${2:-}"

  # Display prompt on stderr so $() captures only the value, not the prompt.
  if [ -n "$default" ]; then
    printf '  %s [%b%s%b]: ' "$prompt" "${_C_CYAN}" "$default" "${_C_RST}" >&2
  else
    printf '  %s: ' "$prompt" >&2
  fi

  local input
  if ! IFS= read -r input; then
    # EOF on stdin — treat as abort
    return 2
  fi

  # Trim leading/trailing whitespace
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"

  case "$input" in
    q|Q) return 2 ;;
    b|B) return 1 ;;
    "")  echo "$default"; return 0 ;;
    *)   echo "$input";   return 0 ;;
  esac
}

# _menu_choice PROMPT CHOICES_ARRAY_NAME DEFAULT_INDEX — numbered choice menu.
#
# Prints a numbered list from the named array, reads a selection (1..N),
# and echoes the chosen value.  DEFAULT_INDEX is 1-based.
# Returns 0 on valid selection, 1 on back, 2 on abort.
_menu_choice() {
  local prompt="$1" arr_name="$2" default_idx="${3:-1}"
  local -n _choices="$arr_name"
  local count=${#_choices[@]}

  # Display numbered list on stderr so $() captures only the chosen value.
  local i
  for ((i = 0; i < count; i++)); do
    local marker=" "
    if [ $((i + 1)) -eq "$default_idx" ]; then
      marker="*"
    fi
    printf '  %b%s %d)%b %s\n' "${_C_GREEN}" "$marker" $((i + 1)) "${_C_RST}" "${_choices[$i]}" >&2
  done

  while true; do
    local raw rc=0
    raw=$(_menu_prompt "$prompt" "$default_idx") || rc=$?
    # Propagate back (1) or abort (2) from _menu_prompt
    [ "$rc" -ne 0 ] && return "$rc"

    # Validate: must be integer 1..count
    case "$raw" in
      ''|*[!0-9]*)
        printf '  %bPlease enter a number between 1 and %d%b\n' "${_C_RED}" "$count" "${_C_RST}" >&2
        continue
        ;;
    esac
    if [ "$raw" -ge 1 ] && [ "$raw" -le "$count" ]; then
      echo "${_choices[$((raw - 1))]}"
      return 0
    fi
    printf '  %bPlease enter a number between 1 and %d%b\n' "${_C_RED}" "$count" "${_C_RST}" >&2
  done
}

# _menu_yesno PROMPT DEFAULT — y/n prompt.
#
# DEFAULT should be "y" or "n".  Return codes:
#   0  = yes
#   1  = no
#   10 = back (user typed 'b')
#   20 = abort (user typed 'q' or EOF)
_menu_yesno() {
  local prompt="$1" default="${2:-n}"
  while true; do
    local raw rc=0
    raw=$(_menu_prompt "$prompt (y/n)" "$default") || rc=$?
    # Propagate back/abort with distinct codes that don't collide with yes/no
    [ "$rc" -eq 1 ] && return 10   # back
    [ "$rc" -eq 2 ] && return 20   # abort

    case "$raw" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   return 1 ;;
      *)
        printf '  %bPlease enter y or n%b\n' "${_C_RED}" "${_C_RST}" >&2
        ;;
    esac
  done
}

# _menu_freetext PROMPT DEFAULT [VALIDATOR] — free-text input with optional validation.
#
# If VALIDATOR function name is provided, calls it with the input value.
# The validator should return 0 on success or 1 on failure (and print its own error to stderr).
# Loops until valid input or back/abort.
# Return codes: 0=value on stdout, 1=back, 2=abort.
_menu_freetext() {
  local prompt="$1" default="${2:-}" validator="${3:-}"
  while true; do
    local raw rc=0
    raw=$(_menu_prompt "$prompt" "$default") || rc=$?
    # Propagate back (1) or abort (2) from _menu_prompt
    [ "$rc" -ne 0 ] && return "$rc"

    if [ -n "$validator" ] && [ -n "$raw" ]; then
      if ! "$validator" "$raw"; then
        continue
      fi
    fi
    echo "$raw"
    return 0
  done
}

# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------

# _menu_validate_algo VALUE — validate single or comma-separated algorithm string.
# Returns 0 if all algorithms are valid, 1 otherwise (prints error).
_menu_validate_algo() {
  local input="$1"
  local algo
  local IFS=','
  for algo in $input; do
    case "$algo" in
      md5|sha1|sha224|sha256|sha384|sha512) ;;
      *)
        printf '  %bInvalid algorithm: %s (use md5, sha1, sha224, sha256, sha384, sha512)%b\n' \
          "${_C_RED}" "$algo" "${_C_RST}" >&2
        return 1
        ;;
    esac
  done
  return 0
}

# _menu_validate_meta_sig VALUE — validate meta signature algorithm.
_menu_validate_meta_sig() {
  case "$1" in
    sha256|md5|none) return 0 ;;
    *)
      printf '  %bInvalid meta-sig: %s (use sha256, md5, none)%b\n' "${_C_RED}" "$1" "${_C_RST}" >&2
      return 1
      ;;
  esac
}

# _menu_validate_dir VALUE — validate that path is an existing directory.
_menu_validate_dir() {
  if [ ! -d "$1" ]; then
    printf '  %bDirectory not found: %s%b\n' "${_C_RED}" "$1" "${_C_RST}" >&2
    return 1
  fi
  return 0
}

# _menu_validate_file VALUE — validate that path is an existing readable file.
_menu_validate_file() {
  if [ ! -f "$1" ]; then
    printf '  %bFile not found: %s%b\n' "${_C_RED}" "$1" "${_C_RST}" >&2
    return 1
  fi
  if [ ! -r "$1" ]; then
    printf '  %bFile not readable: %s%b\n' "${_C_RED}" "$1" "${_C_RST}" >&2
    return 1
  fi
  return 0
}

# _menu_validate_parallel VALUE — validate parallel job count (integer, auto, fraction).
_menu_validate_parallel() {
  case "$1" in
    auto) return 0 ;;
    [0-9]*) return 0 ;;
    [0-9]*/[0-9]*) return 0 ;;
    *)
      printf '  %bInvalid value: %s (use integer, "auto", or fraction like 3/4)%b\n' \
        "${_C_RED}" "$1" "${_C_RST}" >&2
      return 1
      ;;
  esac
}

# _menu_validate_size VALUE — validate human-readable file size (e.g. 10M, 1G, 500K).
_menu_validate_size() {
  if [[ "$1" =~ ^[0-9]+[KMGTkmgt]?$ ]]; then
    return 0
  fi
  printf '  %bInvalid size: %s (use digits with optional K/M/G/T suffix, e.g. 10M)%b\n' \
    "${_C_RED}" "$1" "${_C_RST}" >&2
  return 1
}

# _menu_validate_log_format VALUE — validate log format.
_menu_validate_log_format() {
  case "$1" in
    text|json|csv) return 0 ;;
    *)
      printf '  %bInvalid format: %s (use text, json, csv)%b\n' "${_C_RED}" "$1" "${_C_RST}" >&2
      return 1
      ;;
  esac
}

# _menu_validate_first_run_choice VALUE — validate first-run mismatch handling.
_menu_validate_first_run_choice() {
  case "$1" in
    skip|overwrite|prompt) return 0 ;;
    *)
      printf '  %bInvalid choice: %s (use skip, overwrite, prompt)%b\n' "${_C_RED}" "$1" "${_C_RST}" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Screen Functions
#
# Each returns $_MENU_NEXT (0) to advance, $_MENU_BACK (1) to go back,
# or $_MENU_ABORT (2) to quit.
#
# Navigation from _menu_freetext/_menu_choice: rc 1=back, 2=abort
# Navigation from _menu_yesno: rc 0=yes, 1=no, 10=back, 20=abort
# ---------------------------------------------------------------------------

# _menu_nav_freetext — helper to handle _menu_freetext/_menu_choice return codes.
# Call as: _m_var=$(_menu_freetext ...) || { _menu_nav_freetext $?; return $?; }
_menu_nav_freetext() {
  [ "$1" -eq 2 ] && return "$_MENU_ABORT"
  return "$_MENU_BACK"
}

# _menu_nav_yesno — helper to handle _menu_yesno return codes.
# Returns: 0=yes, 1=no, or propagates back/abort to caller.
# Usage:  local _yrc=0; _menu_yesno ... || _yrc=$?
#         _menu_nav_yesno "$_yrc" && _m_var="y" || _m_var="n"
_menu_nav_yesno() {
  local rc="$1"
  [ "$rc" -eq 20 ] && return "$_MENU_ABORT"
  [ "$rc" -eq 10 ] && return "$_MENU_BACK"
  # rc=0 (yes) or rc=1 (no) — return as-is
  return "$rc"
}

# Screen 1: Mode & Target
_menu_screen_mode_target() {
  _menu_header "Mode & Target (1/5)"

  # --- Mode selection ---
  local mode_choices=("Generate/update checksums" "Verify-only audit (--verify-only)" "Status/diff check (--status)" "Check external manifest (--check FILE)")

  # Determine default index from pre-set globals
  local mode_default=1
  [ "${VERIFY_ONLY:-0}" -eq 1 ] && mode_default=2
  [ "${STATUS_ONLY:-0}" -eq 1 ] && mode_default=3
  [ -n "${CHECK_FILE:-}" ]      && mode_default=4

  local mode_label _rc=0
  mode_label=$(_menu_choice "Select mode" mode_choices "$mode_default") || {
    _menu_nav_freetext $?; return $?
  }

  case "$mode_label" in
    Generate*)   _m_mode="generate" ;;
    Verify*)     _m_mode="verify" ;;
    Status*)     _m_mode="status" ;;
    Check*)      _m_mode="check" ;;
  esac

  # --- Check file (if check mode) ---
  if [ "$_m_mode" = "check" ]; then
    local check_default="${CHECK_FILE:-}"
    _m_check_file=$(_menu_freetext "Manifest file path" "$check_default" _menu_validate_file) || {
      _menu_nav_freetext $?; return $?
    }
  fi

  # --- Target directory ---
  local target_default="${TARGET_DIR:-.}"
  [ -z "$target_default" ] && target_default="."
  _m_target=$(_menu_freetext "Target directory" "$target_default" _menu_validate_dir) || {
    _menu_nav_freetext $?; return $?
  }

  return "$_MENU_NEXT"
}

# Screen 2: Algorithm & Filtering
_menu_screen_algo_filter() {
  _menu_header "Algorithm & Filtering (2/5)"

  # --- Per-file algorithm ---
  if [ "$_m_mode" = "check" ]; then
    _menu_skip_note "algorithm auto-detected from manifest in --check mode"
    _m_algo="${PER_FILE_ALGO:-md5}"
  else
    _m_algo=$(_menu_freetext \
      "Per-file algorithm (md5, sha1, sha224, sha256, sha384, sha512; comma-sep for multi)" \
      "${PER_FILE_ALGO:-md5}" _menu_validate_algo) || {
      _menu_nav_freetext $?; return $?
    }

    # Multi-algo conflict check
    if [[ "$_m_algo" == *,* ]]; then
      if [ "$_m_mode" = "verify" ] || [ "$_m_mode" = "status" ]; then
        printf '  %bMulti-algo is incompatible with --%s; using first algorithm only%b\n' \
          "${_C_YELLOW}" "$_m_mode" "${_C_RST}" >&2
        _m_algo="${_m_algo%%,*}"
      fi
    fi
  fi

  # --- Meta signature algorithm ---
  if [ "$_m_mode" = "check" ]; then
    _menu_skip_note "meta-sig not applicable in --check mode"
    _m_meta_sig="${META_SIG_ALGO:-sha256}"
  else
    _m_meta_sig=$(_menu_freetext "Meta signature algorithm (sha256, md5, none)" \
      "${META_SIG_ALGO:-sha256}" _menu_validate_meta_sig) || {
      _menu_nav_freetext $?; return $?
    }
  fi

  # --- File filtering (not applicable for check mode) ---
  if [ "$_m_mode" = "check" ]; then
    _menu_skip_note "file filtering not applicable in --check mode"
    _m_exclude=""
    _m_include=""
    _m_max_size=""
    _m_min_size=""
    _m_follow_symlinks="n"
  else
    printf '\n  %bFile filtering (press Enter to skip each):%b\n' "${_C_DIM}" "${_C_RST}" >&2

    # Exclude patterns
    local excl_default=""
    if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ] 2>/dev/null; then
      excl_default=$(IFS=','; echo "${EXCLUDE_PATTERNS[*]}")
    fi
    _m_exclude=$(_menu_freetext "Exclude patterns (comma-separated globs)" "$excl_default") || {
      _menu_nav_freetext $?; return $?
    }

    # Include patterns
    local incl_default=""
    if [ ${#INCLUDE_PATTERNS[@]} -gt 0 ] 2>/dev/null; then
      incl_default=$(IFS=','; echo "${INCLUDE_PATTERNS[*]}")
    fi
    _m_include=$(_menu_freetext "Include patterns (comma-separated globs)" "$incl_default") || {
      _menu_nav_freetext $?; return $?
    }

    # Max size (validator loops on bad input; empty = no limit)
    _m_max_size=$(_menu_freetext "Max file size (e.g. 10M, 1G)" "${MAX_SIZE:-}" _menu_validate_size) || {
      _menu_nav_freetext $?; return $?
    }

    # Min size (validator loops on bad input; empty = no limit)
    _m_min_size=$(_menu_freetext "Min file size (e.g. 1K, 100)" "${MIN_SIZE:-}" _menu_validate_size) || {
      _menu_nav_freetext $?; return $?
    }

    # Follow symlinks
    local sym_default="n"
    [ "${FOLLOW_SYMLINKS:-0}" -eq 1 ] && sym_default="y"
    _menu_do_yesno "Follow symlinks" "$sym_default" _m_follow_symlinks || return $?
  fi

  return "$_MENU_NEXT"
}

# Screen 3: Parallelism & Storage
_menu_screen_parallel_storage() {
  _menu_header "Parallelism & Storage (3/5)"

  # --- Parallel hashing jobs ---
  _m_parallel=$(_menu_freetext "Parallel hashing jobs (integer, auto, fraction)" \
    "${PARALLEL_JOBS:-1}" _menu_validate_parallel) || {
    _menu_nav_freetext $?; return $?
  }

  # --- Parallel directories ---
  _m_parallel_dirs=$(_menu_freetext "Parallel directories (integer, auto, fraction)" \
    "${PARALLEL_DIRS:-1}" _menu_validate_parallel) || {
    _menu_nav_freetext $?; return $?
  }

  # --- Batch rules (only for generate mode) ---
  if [ "$_m_mode" = "generate" ]; then
    _m_batch=$(_menu_freetext "Batch rules" "${BATCH_RULES:-0-10M:20,10M-40M:20,>40M:5}") || {
      _menu_nav_freetext $?; return $?
    }
  else
    _m_batch=""
  fi

  # --- Storage options (not applicable for check/status modes) ---
  if [ "$_m_mode" = "check" ] || [ "$_m_mode" = "status" ]; then
    _menu_skip_note "storage options not applicable in --${_m_mode} mode"
    _m_base_name=""
    _m_log_base=""
    _m_store_dir=""
    _m_minimal="n"
  else
    printf '\n  %bStorage & naming:%b\n' "${_C_DIM}" "${_C_RST}" >&2

    _m_base_name=$(_menu_freetext "Sidecar base name" "${BASE_NAME:-#####checksums#####}") || {
      _menu_nav_freetext $?; return $?
    }

    _m_log_base=$(_menu_freetext "Log base name (Enter = same as base name)" "${LOG_BASE:-}") || {
      _menu_nav_freetext $?; return $?
    }

    _m_store_dir=$(_menu_freetext "Central manifest store directory (Enter = alongside files)" "${STORE_DIR:-}") || {
      _menu_nav_freetext $?; return $?
    }

    # Minimal mode
    local min_default="n"
    [ "${MINIMAL:-0}" -eq 1 ] && min_default="y"
    _menu_do_yesno "Minimal mode (hash-only, no .meta/.log)" "$min_default" _m_minimal || return $?
  fi

  # --- Directory handling (not for check mode) ---
  if [ "$_m_mode" = "check" ]; then
    _m_skip_empty="y"
    _m_allow_root="n"
  else
    printf '\n  %bDirectory handling:%b\n' "${_C_DIM}" "${_C_RST}" >&2

    # Skip empty directories (default: on)
    local se_default="y"
    [ "${SKIP_EMPTY:-1}" -eq 0 ] && se_default="n"
    _menu_do_yesno "Skip empty directories" "$se_default" _m_skip_empty || return $?

    # Allow root sidefiles (default: no — root stays clean)
    if [ "$_m_mode" = "generate" ] || [ "$_m_mode" = "verify" ]; then
      local ar_default="n"
      [ "${NO_ROOT_SIDEFILES:-1}" -eq 0 ] && ar_default="y"
      _menu_do_yesno "Allow sidecar files in root directory" "$ar_default" _m_allow_root || return $?
    else
      _m_allow_root="n"
    fi
  fi

  return "$_MENU_NEXT"
}

# _menu_do_yesno PROMPT DEFAULT VAR_NAME — helper to run yesno and set a variable.
#
# Handles back/abort propagation. On yes, sets the named variable to "y";
# on no, sets it to "n". Returns 0 normally, or $_MENU_BACK / $_MENU_ABORT.
_menu_do_yesno() {
  local _prompt="$1" _default="$2" _var="$3"
  local _yrc=0
  _menu_yesno "$_prompt" "$_default" || _yrc=$?
  if [ "$_yrc" -eq 20 ]; then return "$_MENU_ABORT"; fi
  if [ "$_yrc" -eq 10 ]; then return "$_MENU_BACK"; fi
  if [ "$_yrc" -eq 0 ]; then
    eval "$_var"'="y"'
  else
    eval "$_var"'="n"'
  fi
  return 0
}

# Screen 4: Run Control, Output & First-Run
_menu_screen_control() {
  _menu_header "Run Control & Output (4/5)"

  # --- Dry-run (not for status/check) ---
  if [ "$_m_mode" = "status" ] || [ "$_m_mode" = "check" ]; then
    _menu_skip_note "dry-run not applicable in --${_m_mode} mode"
    _m_dry_run="n"
  else
    local dr_default="n"
    [ "${DRY_RUN:-0}" -eq 1 ] && dr_default="y"
    _menu_do_yesno "Dry-run (simulate, no writes)" "$dr_default" _m_dry_run || return $?
  fi

  # --- Force rebuild (not for status/check/verify) ---
  if [ "$_m_mode" != "generate" ]; then
    _menu_skip_note "force-rebuild not applicable in --${_m_mode} mode"
    _m_force_rebuild="n"
  else
    local fr_default="n"
    [ "${FORCE_REBUILD:-0}" -eq 1 ] && fr_default="y"
    _menu_do_yesno "Force rebuild (ignore manifests)" "$fr_default" _m_force_rebuild || return $?
  fi

  # --- No-reuse (generate mode only, after force-rebuild) ---
  if [ "$_m_mode" = "generate" ]; then
    local nr_default="n"
    [ "${NO_REUSE:-0}" -eq 1 ] && nr_default="y"
    _menu_do_yesno "Disable reuse (force rehash all files)" "$nr_default" _m_no_reuse || return $?
  else
    _m_no_reuse="n"
  fi

  # --- Auto-confirm (default to yes since user is already interacting) ---
  _menu_do_yesno "Auto-confirm prompts (--assume-yes)" "y" _m_assume_yes || return $?

  # --- Log format ---
  _m_log_format=$(_menu_freetext "Log format (text, json, csv)" \
    "${LOG_FORMAT:-text}" _menu_validate_log_format) || {
    _menu_nav_freetext $?; return $?
  }

  # --- Verbose ---
  local v_default="n"
  [ "${VERBOSE:-0}" -ge 1 ] && v_default="y"
  _menu_do_yesno "Verbose output" "$v_default" _m_verbose || return $?

  # --- Debug ---
  local d_default="n"
  [ "${DEBUG:-0}" -ge 1 ] && d_default="y"
  _menu_do_yesno "Debug output" "$d_default" _m_debug || return $?

  # --- Quiet ---
  local q_default="n"
  [ "${QUIET:-0}" -eq 1 ] && q_default="y"
  _menu_do_yesno "Quiet mode (errors only)" "$q_default" _m_quiet || return $?

  # --- Progress ---
  local p_default="y"
  [ "${PROGRESS:-1}" -eq 0 ] && p_default="n"
  _menu_do_yesno "Live progress reporting" "$p_default" _m_progress || return $?

  # --- MD5 verification details in planning (generate/verify modes) ---
  if [ "$_m_mode" = "generate" ] || [ "$_m_mode" = "verify" ]; then
    local md_default="y"
    [ "${VERIFY_MD5_DETAILS:-1}" -eq 0 ] && md_default="n"
    _menu_do_yesno "MD5 verification details in planning" "$md_default" _m_md5_details || return $?
  else
    _m_md5_details="y"
  fi

  # --- First-run (only for generate mode, not minimal) ---
  if [ "$_m_mode" != "generate" ]; then
    _menu_skip_note "first-run not applicable in --${_m_mode} mode"
    _m_first_run="n"
    _m_first_run_choice=""
    _m_first_run_keep="n"
  elif [ "$_m_minimal" = "y" ]; then
    _menu_skip_note "first-run disabled in minimal mode"
    _m_first_run="n"
    _m_first_run_choice=""
    _m_first_run_keep="n"
  else
    local frun_default="n"
    [ "${FIRST_RUN:-0}" -eq 1 ] && frun_default="y"
    _menu_do_yesno "Enable first-run bootstrap mode" "$frun_default" _m_first_run || return $?

    if [ "$_m_first_run" = "y" ]; then
      # First-run choice
      _m_first_run_choice=$(_menu_freetext \
        "First-run mismatch handling (skip, overwrite, prompt)" \
        "${FIRST_RUN_CHOICE:-prompt}" _menu_validate_first_run_choice) || {
        _menu_nav_freetext $?; return $?
      }

      # First-run keep
      local fk_default="n"
      [ "${FIRST_RUN_KEEP:-0}" -eq 1 ] && fk_default="y"
      _menu_do_yesno "Keep first-run log after overwrites" "$fk_default" _m_first_run_keep || return $?
    else
      _m_first_run_choice=""
      _m_first_run_keep="n"
    fi
  fi

  return "$_MENU_NEXT"
}

# ---------------------------------------------------------------------------
# Command Construction
# ---------------------------------------------------------------------------

# _menu_build_command — assemble _menu_args array and _menu_cmd_str from _m_* state.
#
# Only includes flags that differ from defaults, keeping the output clean.
# The display string quotes values containing spaces or special characters.
_menu_build_command() {
  _menu_args=()
  _menu_cmd_str="checksums"

  # --- Mode flags ---
  case "$_m_mode" in
    verify)
      _menu_args+=(--verify-only)
      _menu_cmd_str+=" --verify-only"
      ;;
    status)
      _menu_args+=(--status)
      _menu_cmd_str+=" --status"
      ;;
    check)
      _menu_args+=(--check "$_m_check_file")
      _menu_cmd_str+=" --check '$_m_check_file'"
      ;;
  esac

  # --- Algorithm (only if non-default) ---
  if [ "$_m_algo" != "md5" ] && [ "$_m_mode" != "check" ]; then
    _menu_args+=(-a "$_m_algo")
    _menu_cmd_str+=" -a $_m_algo"
  fi
  if [ "$_m_meta_sig" != "sha256" ] && [ "$_m_mode" != "check" ]; then
    _menu_args+=(-m "$_m_meta_sig")
    _menu_cmd_str+=" -m $_m_meta_sig"
  fi

  # --- File filtering ---
  if [ -n "$_m_exclude" ]; then
    _menu_args+=(--exclude "$_m_exclude")
    _menu_cmd_str+=" --exclude '$_m_exclude'"
  fi
  if [ -n "$_m_include" ]; then
    _menu_args+=(--include "$_m_include")
    _menu_cmd_str+=" --include '$_m_include'"
  fi
  if [ -n "$_m_max_size" ]; then
    _menu_args+=(--max-size "$_m_max_size")
    _menu_cmd_str+=" --max-size $_m_max_size"
  fi
  if [ -n "$_m_min_size" ]; then
    _menu_args+=(--min-size "$_m_min_size")
    _menu_cmd_str+=" --min-size $_m_min_size"
  fi
  if [ "$_m_follow_symlinks" = "y" ]; then
    _menu_args+=(-L)
    _menu_cmd_str+=" -L"
  fi

  # --- Parallelism ---
  if [ "$_m_parallel" != "1" ]; then
    _menu_args+=(-p "$_m_parallel")
    _menu_cmd_str+=" -p $_m_parallel"
  fi
  if [ "$_m_parallel_dirs" != "1" ]; then
    _menu_args+=(-P "$_m_parallel_dirs")
    _menu_cmd_str+=" -P $_m_parallel_dirs"
  fi
  if [ -n "$_m_batch" ] && [ "$_m_batch" != "0-10M:20,10M-40M:20,>40M:5" ]; then
    _menu_args+=(-b "$_m_batch")
    _menu_cmd_str+=" -b '$_m_batch'"
  fi

  # --- Storage ---
  if [ -n "$_m_base_name" ] && [ "$_m_base_name" != "#####checksums#####" ]; then
    _menu_args+=(-f "$_m_base_name")
    _menu_cmd_str+=" -f '$_m_base_name'"
  fi
  if [ -n "$_m_log_base" ]; then
    _menu_args+=(-l "$_m_log_base")
    _menu_cmd_str+=" -l '$_m_log_base'"
  fi
  if [ -n "$_m_store_dir" ]; then
    _menu_args+=(-D "$_m_store_dir")
    _menu_cmd_str+=" -D '$_m_store_dir'"
  fi
  if [ "$_m_minimal" = "y" ]; then
    _menu_args+=(-M)
    _menu_cmd_str+=" -M"
  fi

  # --- Run control ---
  if [ "$_m_dry_run" = "y" ]; then
    _menu_args+=(-n)
    _menu_cmd_str+=" -n"
  fi
  if [ "$_m_force_rebuild" = "y" ]; then
    _menu_args+=(-r)
    _menu_cmd_str+=" -r"
  fi
  if [ "$_m_no_reuse" = "y" ]; then
    _menu_args+=(-R)
    _menu_cmd_str+=" -R"
  fi
  if [ "$_m_assume_yes" = "y" ]; then
    _menu_args+=(-y)
    _menu_cmd_str+=" -y"
  fi

  # --- Output ---
  if [ "$_m_log_format" != "text" ]; then
    _menu_args+=(-o "$_m_log_format")
    _menu_cmd_str+=" -o $_m_log_format"
  fi
  if [ "$_m_verbose" = "y" ]; then
    _menu_args+=(-v)
    _menu_cmd_str+=" -v"
  fi
  if [ "$_m_debug" = "y" ]; then
    _menu_args+=(-d)
    _menu_cmd_str+=" -d"
  fi
  if [ "$_m_quiet" = "y" ]; then
    _menu_args+=(-q)
    _menu_cmd_str+=" -q"
  fi
  if [ "$_m_progress" = "n" ]; then
    _menu_args+=(-Q)
    _menu_cmd_str+=" -Q"
  fi
  if [ "$_m_md5_details" = "n" ]; then
    _menu_args+=(-z)
    _menu_cmd_str+=" -z"
  fi

  # --- Directory handling (only emit when changed from defaults) ---
  if [ "$_m_skip_empty" = "n" ]; then
    _menu_args+=(--no-skip-empty)
    _menu_cmd_str+=" --no-skip-empty"
  fi
  if [ "$_m_allow_root" = "y" ]; then
    _menu_args+=(--allow-root-sidefiles)
    _menu_cmd_str+=" --allow-root-sidefiles"
  fi

  # --- First-run ---
  if [ "$_m_first_run" = "y" ]; then
    _menu_args+=(-F)
    _menu_cmd_str+=" -F"
    if [ -n "$_m_first_run_choice" ] && [ "$_m_first_run_choice" != "prompt" ]; then
      _menu_args+=(-C "$_m_first_run_choice")
      _menu_cmd_str+=" -C $_m_first_run_choice"
    fi
    if [ "$_m_first_run_keep" = "y" ]; then
      _menu_args+=(-K)
      _menu_cmd_str+=" -K"
    fi
  fi

  # --- Target directory (always last) ---
  _menu_args+=("$_m_target")
  # Quote target if it contains spaces
  case "$_m_target" in
    *[[:space:]]*) _menu_cmd_str+=" '$_m_target'" ;;
    *)             _menu_cmd_str+=" $_m_target" ;;
  esac
}

# _menu_show_preview — display the constructed command in a formatted box.
_menu_show_preview() {
  printf '\n%b' "${_C_BOLD}" >&2
  printf '  ┌──────────────────────────────────────────────────┐\n' >&2
  printf '  │  Command preview                                 │\n' >&2
  printf '  └──────────────────────────────────────────────────┘\n' >&2
  printf '%b' "${_C_RST}" >&2
  printf '\n  %b%s%b\n\n' "${_C_GREEN}" "$_menu_cmd_str" "${_C_RST}" >&2
}

# Screen 5: Review & Execute
_menu_screen_review() {
  _menu_build_command
  _menu_show_preview

  local review_choices=("Run this command now" "Print command and exit" "Go back and edit" "Abort")
  local choice
  choice=$(_menu_choice "Choose action" review_choices 1) || {
    _menu_nav_freetext $?; return $?
  }

  case "$choice" in
    "Run this command now")
      printf '\n'
      _menu_exec
      ;;
    "Print command and exit")
      printf '\n%s\n' "$_menu_cmd_str"
      exit 0
      ;;
    "Go back and edit")
      return "$_MENU_BACK"
      ;;
    "Abort")
      log "Aborted by user"
      exit 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

# _menu_exec — execute the constructed command in-process.
#
# Resets MENU_MODE and OPTIND, calls parse_args with the built argument array,
# then dispatches to the appropriate mode handler. Avoids re-sourcing libraries.
_menu_exec() {
  MENU_MODE=0
  OPTIND=1
  parse_args "${_menu_args[@]}"

  if [ -n "${CHECK_FILE:-}" ]; then
    run_check_mode
  elif [ "${STATUS_ONLY:-0}" -eq 1 ]; then
    run_status
  else
    run_checksums
  fi
}

# ---------------------------------------------------------------------------
# Entry Point
# ---------------------------------------------------------------------------

# run_menu — top-level interactive menu entry point.
#
# Requires an interactive terminal (TTY on stdin and stdout).  Reads current
# global values as defaults (supports --config and pre-set CLI flags alongside
# --menu).  Walks through 5 screens and either executes the command or prints
# it for copy/paste.
run_menu() {
  # Menu mode requires an interactive terminal for user input and colored output.
  # The _MENU_FORCE_TTY escape hatch is for automated testing only.
  if [ "${_MENU_FORCE_TTY:-0}" -ne 1 ]; then
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      fatal "--menu requires an interactive terminal (TTY on stdin and stdout)"
    fi
  fi

  # Welcome header — stderr so "print & exit" produces only the command on stdout
  printf '\n%b%s v%s — Interactive Command Builder%b\n' \
    "${_C_BOLD}" "${ME:-checksums}" "${VER:-}" "${_C_RST}" >&2
  printf '  Build a checksums command step-by-step.\n' >&2
  printf '  Press Enter to accept [defaults]. Type %bb%b to go back, %bq%b to abort.\n' \
    "${_C_CYAN}" "${_C_RST}" "${_C_CYAN}" "${_C_RST}" >&2

  # Screen dispatch table
  local _screen_funcs=( _menu_screen_mode_target _menu_screen_algo_filter _menu_screen_parallel_storage _menu_screen_control _menu_screen_review )
  local _total=${#_screen_funcs[@]}
  local _idx=0

  while [ "$_idx" -lt "$_total" ]; do
    local rc=0
    "${_screen_funcs[$_idx]}" || rc=$?

    case "$rc" in
      "$_MENU_NEXT")
        _idx=$((_idx + 1))
        ;;
      "$_MENU_BACK")
        if [ "$_idx" -gt 0 ]; then
          _idx=$((_idx - 1))
        fi
        ;;
      "$_MENU_ABORT")
        log "Aborted by user"
        exit 0
        ;;
    esac
  done
}
