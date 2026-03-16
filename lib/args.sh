#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# shellcheck disable=SC2034
# args.sh
#
# Purpose:
#   Parse CLI options and normalize global runtime settings for the checksums tool.
#   This module preserves the original semantics while adding:
#     - --skip-empty (affirmative; default already enabled via SKIP_EMPTY=1 in init.sh)
#     - --allow-root-sidefiles (affirmative; flips default NO_ROOT_SIDEFILES=1 to 0)
#     - --config FILE (explicit config file path)
#   It also guards against missing positional DIRECTORY under `set -u`.
#
# Design notes:
#   - We use getopts with the -: hack to support GNU-style long options.
#   - All global variables are defined in init.sh; args.sh only overrides based on CLI.
#   - After parsing, filenames derived from BASE_NAME and LOG_BASE are normalized.
#   - We validate supported values and provide helpful errors via usage() and fatal().
#
# Expected globals (from init.sh):
#   BASE_NAME, PER_FILE_ALGO, META_SIG_ALGO, LOG_BASE, DRY_RUN, DEBUG, VERBOSE, YES,
#   ASSUME_NO, FORCE_REBUILD, FIRST_RUN, FIRST_RUN_CHOICE, PARALLEL_JOBS, LOG_FORMAT,
#   VERIFY_ONLY, CONFIG_FILE, SKIP_EMPTY, NO_ROOT_SIDEFILES,
#   SUM_FILENAME, META_FILENAME, LOG_FILENAME
#
# Provided functions (sourced elsewhere):
#   usage()    - prints help and exits (or returns)
#   fatal(msg) - prints error and exits
#   record_error(msg) - records a non-fatal parsing warning (optional)
#
# Example:
#   parse_args -a sha256 -o json --assume-yes --allow-root-sidefiles /path/to/project
#   TARGET_DIR will be set and globals updated to match CLI options.
#
# NOTE: This file focuses on robust, portable parsing and clear, explicit comments
# for maintainers. Keep comments near the code they document so future edits stay clear.

# _load_config — safe key=value config parser (no code execution)
#
# Reads a config file line by line. Blank lines and lines starting with #
# are skipped. Each remaining line must contain KEY=VALUE. Leading/trailing
# whitespace is trimmed from both key and value. Matching outer quotes
# ("..." or '...') are stripped from the value. Known keys are mapped to
# their corresponding globals; unknown keys produce a warning.
#
# Old bash-sourced configs containing array syntax (KEY=(...)) are detected
# and rejected with a fatal error and migration hint.
_load_config() {
  local file="$1"
  local line_num=0 line key val

  # Detect old bash-sourced format: array assignments like KEY=(...)
  if grep -qE '^[[:space:]]*[A-Za-z_]+[[:space:]]*=\s*\(' "$file" 2>/dev/null; then
    fatal "Config file '$file' uses old bash array syntax (e.g. PATTERNS=(...)). Please convert to key=value format. See example/checksums.conf for the new format."
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))

    # Strip leading whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    # Strip trailing whitespace
    line="${line%"${line##*[![:space:]]}"}"

    # Skip blank lines and comments
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue

    # Must contain =
    if [[ "$line" != *=* ]]; then
      log "WARNING: config $file:$line_num: invalid line (no '='): $line"
      continue
    fi

    # Split on first =
    key="${line%%=*}"
    val="${line#*=}"

    # Trim whitespace from key
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"

    # Trim whitespace from value
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    # Strip matching outer quotes
    if [ "${#val}" -ge 2 ]; then
      case "$val" in
        \"*\") val="${val:1:${#val}-2}" ;;
        \'*\') val="${val:1:${#val}-2}" ;;
      esac
    fi

    # Map known keys to globals
    case "$key" in
      BASE_NAME)          BASE_NAME="$val" ;;
      PER_FILE_ALGO)      PER_FILE_ALGO="$val" ;;
      META_SIG_ALGO)      META_SIG_ALGO="$val" ;;
      LOG_BASE)           LOG_BASE="$val" ;;
      LOG_FORMAT)         LOG_FORMAT="$val" ;;
      DRY_RUN)            DRY_RUN="$val" ;;
      DEBUG)              DEBUG="$val" ;;
      VERBOSE)            VERBOSE="$val" ;;
      YES)                YES="$val" ;;
      ASSUME_NO)          ASSUME_NO="$val" ;;
      FORCE_REBUILD)      FORCE_REBUILD="$val" ;;
      FIRST_RUN)          FIRST_RUN="$val" ;;
      FIRST_RUN_CHOICE)   FIRST_RUN_CHOICE="$val" ;;
      FIRST_RUN_KEEP)     FIRST_RUN_KEEP="$val" ;;
      PARALLEL_JOBS)      PARALLEL_JOBS="$val" ;;
      PARALLEL_DIRS)      PARALLEL_DIRS="$val" ;;
      BATCH_RULES)        BATCH_RULES="$val" ;;
      VERIFY_ONLY)        VERIFY_ONLY="$val" ;;
      VERIFY_MD5_DETAILS) VERIFY_MD5_DETAILS="$val" ;;
      STATUS_ONLY)        STATUS_ONLY="$val" ;;
      CHECK_FILE)         CHECK_FILE="$val" ;;
      SKIP_EMPTY)         SKIP_EMPTY="$val" ;;
      NO_REUSE)           NO_REUSE="$val" ;;
      NO_ROOT_SIDEFILES)  NO_ROOT_SIDEFILES="$val" ;;
      FOLLOW_SYMLINKS)    FOLLOW_SYMLINKS="$val" ;;
      PROGRESS)           PROGRESS="$val" ;;
      MINIMAL)            MINIMAL="$val" ;;
      QUIET)              QUIET="$val" ;;
      STORE_DIR)          STORE_DIR="$val" ;;
      MAX_SIZE)           MAX_SIZE="$val" ;;
      MIN_SIZE)           MIN_SIZE="$val" ;;
      EXCLUDE_PATTERNS)
        # Split comma-separated globs into individual array elements
        if [ -n "$val" ]; then
          local _ep
          IFS=',' read -ra _ep <<< "$val"
          EXCLUDE_PATTERNS+=("${_ep[@]}")
        fi
        ;;
      INCLUDE_PATTERNS)
        # Split comma-separated globs into individual array elements
        if [ -n "$val" ]; then
          local _ip
          IFS=',' read -ra _ip <<< "$val"
          INCLUDE_PATTERNS+=("${_ip[@]}")
        fi
        ;;
      *)
        log "WARNING: config $file:$line_num: unknown key '$key' (ignored)"
        ;;
    esac
  done < "$file"
}

parse_args() {
  # NOTE: Global defaults (BASE_NAME, LOG_BASE, LOG_FORMAT, VERIFY_ONLY, ASSUME_NO,
  # CONFIG_FILE, FIRST_RUN_KEEP, VERIFY_MD5_DETAILS, etc.) are declared and
  # initialized in lib/init.sh. This function should only parse CLI options and
  # apply overrides. Do not re-declare global defaults here to avoid surprising
  # overrides and to keep a single source of truth for runtime defaults.

  # -------------------------
  # Config pre-scan (must run before getopts)
  # -------------------------
  # We need TARGET_DIR and --config before the getopts loop so that the config
  # file is sourced here — BEFORE getopts processes CLI flags. This guarantees
  # that every CLI flag set by getopts overrides whatever the config file set,
  # rather than the other way around.
  #
  # We also pick up -f/--base-name so a custom BASE_NAME is reflected in the
  # default config path ($TARGET_DIR/${BASE_NAME}.conf).
  #
  # Only the two-token forms (-f VALUE, --base-name VALUE, --config VALUE) and
  # the single-token = form (--config=VALUE, --base-name=VALUE) are handled.
  # The rare concatenated form (-fVALUE) is not detected here; callers relying
  # on that form for the default config path should use --config explicitly.
  local _pi=1 _prescan_config="" _prescan_target=""
  while [ "$_pi" -le "$#" ]; do
    local _pa="${!_pi}"
    case "$_pa" in
      --config)
        _pi=$(( _pi + 1 )); _prescan_config="${!_pi:-}"
        ;;
      --config=*)
        _prescan_config="${_pa#--config=}"
        ;;
      -f)
        _pi=$(( _pi + 1 )); BASE_NAME="${!_pi:-$BASE_NAME}"
        ;;
      --base-name)
        _pi=$(( _pi + 1 )); BASE_NAME="${!_pi:-$BASE_NAME}"
        ;;
      --base-name=*)
        BASE_NAME="${_pa#--base-name=}"
        ;;
      # Flags that consume the next token as their value — skip that token so
      # a value that looks like a path is not mistaken for TARGET_DIR.
      -a|-m|-l|-c|-C|-p|-P|-b|-o|-D|-e|-i| \
      --per-file-algo|--meta-sig|--log-base|--check|--first-run-choice|--parallel|--parallel-dirs|--batch|--output|--log-format|--store-dir|--exclude|--include|--max-size|--min-size)
        _pi=$(( _pi + 1 ))
        ;;
      --)
        # End-of-options sentinel — next token is TARGET_DIR
        _pi=$(( _pi + 1 ))
        [ "$_pi" -le "$#" ] && _prescan_target="${!_pi}"
        break
        ;;
      -*)
        # Single-token flag with no argument to consume
        ;;
      *)
        # Positional argument — last one wins as TARGET_DIR candidate
        _prescan_target="$_pa"
        ;;
    esac
    _pi=$(( _pi + 1 ))
  done

  # Load the config file now so getopts below can override its values with CLI flags.
  # Explicit --config takes priority over the per-directory default.
  if [ -n "$_prescan_config" ]; then
    CONFIG_FILE="$_prescan_config"
    if [ -f "$CONFIG_FILE" ]; then
      _load_config "$CONFIG_FILE"
    else
      fatal "Config file specified but not found: $CONFIG_FILE"
    fi
  elif [ -n "$_prescan_target" ]; then
    local _default_conf="$_prescan_target/${BASE_NAME}.conf"
    if [ -f "$_default_conf" ]; then
      _load_config "$_default_conf"
    fi
  fi

  # -------------------------
  # getopts setup
  # -------------------------
  # The optstring lists short options. Options that take an argument are followed
  # by ':' (e.g., f:). The trailing '-:' enables the getopts long-option hack:
  # when a long option is encountered, getopts sets opt='-' and OPTARG to the
  # long option name; we handle it in the '-' branch below.
  #
  # Short flags included: f a m l n d v r R F C z p P b o y V h K Q M S
  while getopts "f:a:c:m:l:ndvrRFC:p:P:b:o:yVhKzSQMqD:e:i:L-:" opt 2>/dev/null; do
    case "$opt" in
      # -------------------------
      # Short options (legacy)
      # -------------------------
      # Each short option mirrors a long option handled below. Keep comments
      # describing the semantic effect so maintainers can map short->long easily.
      f) BASE_NAME=$OPTARG ;;            # -f BASE_NAME : base name for .md5/.meta/.log
      a) PER_FILE_ALGO=$OPTARG; _ALGO_EXPLICIT=1 ;;  # -a ALGO : per-file checksum algorithm
      c) CHECK_FILE=$OPTARG ;;            # -c FILE : verify against external manifest
      m) META_SIG_ALGO=$OPTARG ;;        # -m sha256|md5|none : meta signature algorithm
      l) LOG_BASE=$OPTARG ;;             # -l LOG_BASE : base name for per-dir logs
      n) DRY_RUN=1 ;;                    # -n : dry run (no writes)
      d) DEBUG=$((DEBUG+1)) ;;           # -d : debug (repeatable; increases verbosity)
      v) VERBOSE=$((VERBOSE+1)) ;;       # -v : verbose (repeatable)
      r) FORCE_REBUILD=1 ;;              # -r : force rebuild ignoring manifests
      R) NO_REUSE=1 ;;                   # -R : disable reuse heuristics
      F) FIRST_RUN=1 ;;                  # -F : first-run verification/bootstrap mode
      C) FIRST_RUN_CHOICE=$OPTARG ;;     # -C choice : skip|overwrite|prompt for first-run
      K) FIRST_RUN_KEEP=1 ;;             # -K : keep first-run log after overwrites (audit)
      z) VERIFY_MD5_DETAILS=0 ;;         # -z : disable md5-details (no-md5-details)
      p) PARALLEL_JOBS=$OPTARG ;;        # -p N : number of parallel hashing jobs
      P) PARALLEL_DIRS=$OPTARG ;;        # -P N : number of parallel directory workers
      b) BATCH_RULES=$OPTARG ;;          # -b RULES : adaptive batching rules string
      o) LOG_FORMAT=$OPTARG ;;           # -o FORMAT : text | json | csv
      y) YES=1 ;;                        # -y : assume-yes (non-interactive)
      V) VERIFY_ONLY=1 ;;                # -V : verify-only audit mode (no writes)
      S) STATUS_ONLY=1 ;;                # -S : status/diff mode (read-only)
      Q) PROGRESS=0 ;;                   # -Q : disable progress reporting
      M) MINIMAL=1 ;;                    # -M : minimal mode (hash-only, no sidecars)
      q) QUIET=1 ;;                      # -q : quiet mode (errors only)
      L) FOLLOW_SYMLINKS=1 ;;            # -L : follow symbolic links
      D) STORE_DIR=$OPTARG ;;            # -D DIR : central manifest store directory
      e)                                 # -e PATTERN : exclude files matching glob (repeatable)
        local _ep
        IFS=',' read -ra _ep <<< "$OPTARG"
        EXCLUDE_PATTERNS+=("${_ep[@]}")
        ;;
      i)                                 # -i PATTERN : include only files matching glob (repeatable)
        local _ip
        IFS=',' read -ra _ip <<< "$OPTARG"
        INCLUDE_PATTERNS+=("${_ip[@]}")
        ;;
      h) usage; exit 0 ;;                # -h : help

      # -------------------------
      # Long options (getopts -: hack)
      # -------------------------
      # When getopts sees a long option, it sets opt='-' and OPTARG to the long
      # option name. We then handle the long option names here. For options that
      # take a value we consume the next positional parameter via ${!OPTIND}
      # and increment OPTIND.
      -)
        case "$OPTARG" in
          # informational
          version)
            printf '%s version %s\n' "${ME:-checksums}" "${VER:-unknown}"
            exit 0
            ;;
          help)
            usage; exit 0
            ;;

          # affirmative / toggles (no argument)
          assume-yes)
            YES=1
            ;;
          assume-no|no)
            ASSUME_NO=1
            ;;
          dry-run)
            DRY_RUN=1
            ;;
          debug)
            # Increase debug level (repeatable)
            DEBUG=$((DEBUG+1))
            ;;
          verbose)
            # Increase verbosity level (repeatable)
            VERBOSE=$((VERBOSE+1))
            ;;
          force-rebuild)
            FORCE_REBUILD=1
            ;;
          no-reuse)
            NO_REUSE=1
            ;;
          first-run)
            FIRST_RUN=1
            ;;
          first-run-keep)
            FIRST_RUN_KEEP=1
            ;;
          skip-empty)
            # Affirmative: ensure SKIP_EMPTY enabled (default already 1 in init.sh)
            SKIP_EMPTY=1
            ;;
          no-skip-empty)
            # Disable skipping empty/container-only directories
            SKIP_EMPTY=0
            ;;
          md5-details)
            # Enable optional detailed MD5 verification on .md5-only dirs during planning
            VERIFY_MD5_DETAILS=1
            ;;
          no-md5-details)
            # Disable md5-details in planning
            VERIFY_MD5_DETAILS=0
            ;;
          check)
            # --check FILE : verify files against external manifest (sha256sum -c interop)
            CHECK_FILE="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          verify-only)
            VERIFY_ONLY=1
            ;;
          status)
            STATUS_ONLY=1
            ;;
          no-progress)
            PROGRESS=0
            ;;
          quiet)
            QUIET=1
            ;;
          minimal)
            MINIMAL=1
            ;;
          allow-root-sidefiles)
            # Affirmative: allow sidecar files (.md5/.meta/.log) in root (default is protected)
            NO_ROOT_SIDEFILES=0
            ;;
          follow-symlinks)
            # Follow symbolic links when scanning directories and files
            FOLLOW_SYMLINKS=1
            ;;
          no-follow-symlinks)
            # Do not follow symbolic links (default behavior)
            FOLLOW_SYMLINKS=0
            ;;
          store-dir)
            STORE_DIR="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          exclude)
            # --exclude PATTERN : exclude files matching basename glob (repeatable)
            local _ep_val="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            local _ep
            IFS=',' read -ra _ep <<< "$_ep_val"
            EXCLUDE_PATTERNS+=("${_ep[@]}")
            ;;
          include)
            # --include PATTERN : include only files matching basename glob (repeatable)
            local _ip_val="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            local _ip
            IFS=',' read -ra _ip <<< "$_ip_val"
            INCLUDE_PATTERNS+=("${_ip[@]}")
            ;;
          max-size)
            # --max-size SIZE : skip files larger than SIZE (long-only, no short flag)
            MAX_SIZE="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          min-size)
            # --min-size SIZE : skip files smaller than SIZE (long-only, no short flag)
            MIN_SIZE="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;

          # -------------------------
          # Long options that take an argument
          # -------------------------
          # For these we read the next positional parameter using indirect expansion.
          base-name)
            BASE_NAME="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          per-file-algo)
            PER_FILE_ALGO="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            _ALGO_EXPLICIT=1
            ;;
          meta-sig)
            META_SIG_ALGO="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          log-base)
            LOG_BASE="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          config)
            # --config FILE : explicit config file path to load before running
            CONFIG_FILE="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          first-run-choice)
            FIRST_RUN_CHOICE="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          parallel)
            PARALLEL_JOBS="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          parallel-dirs)
            PARALLEL_DIRS="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          batch)
            BATCH_RULES="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          output|log-format)
            LOG_FORMAT="${!OPTIND}"; OPTIND=$((OPTIND + 1))
            ;;
          *)
            # Unknown long option: show usage and exit non-zero
            usage
            exit 1
            ;;
        esac
        ;;
      *)
        # Unknown short option or parsing error
        usage
        exit 1
        ;;
    esac
  done

  # -------------------------
  # Post-parsing: shift to remaining positionals
  # -------------------------
  shift $((OPTIND - 1))

  # -------------------------
  # Defaults and validation
  # -------------------------
  # Provide a safe default for BATCH_RULES if none was supplied.
  BATCH_RULES="${BATCH_RULES:-0-10M:20,10M-40M:20,>40M:5}"

  # Validate BATCH_RULES format: comma-separated "LOW-HIGH:COUNT" or ">HIGH:COUNT"
  # Accept optional K/M/G suffixes. If invalid, record a warning and fall back.
  if ! [[ "$BATCH_RULES" =~ ^([0-9]+[KMG]?-[0-9]+[KMG]?:[0-9]+,)*([0-9]+[KMG]?-[0-9]+[KMG]?:[0-9]+|>[0-9]+[KMG]?:[0-9]+)$ ]]; then
    record_error "Invalid --batch/-b rules format: '$BATCH_RULES'. Falling back to default."
    BATCH_RULES="0-10M:20,10M-40M:20,>40M:5"
  fi

  # Minimal mode: force-disable first-run (no .meta/.log to bootstrap)
  if [ "${MINIMAL:-0}" -eq 1 ] && [ "${FIRST_RUN:-0}" -eq 1 ]; then
    FIRST_RUN=0
  fi

  # STATUS_ONLY is read-only; conflicts with write-oriented modes
  if [ "${STATUS_ONLY:-0}" -eq 1 ]; then
    if [ "${DRY_RUN:-0}" -eq 1 ] || [ "${FORCE_REBUILD:-0}" -eq 1 ] || [ "${FIRST_RUN:-0}" -eq 1 ]; then
      fatal "--status is read-only and cannot be combined with --dry-run, --force-rebuild, or --first-run"
    fi
  fi

  # CHECK_FILE mode: verify against external manifest (read-only, conflicts with write modes)
  if [ -n "${CHECK_FILE:-}" ]; then
    [ "${STATUS_ONLY:-0}" -eq 1 ] && fatal "--check is incompatible with --status"
    [ "${VERIFY_ONLY:-0}" -eq 1 ] && fatal "--check is incompatible with --verify-only"
    [ "${FIRST_RUN:-0}" -eq 1 ] && fatal "--check is incompatible with --first-run"
    [ "${DRY_RUN:-0}" -eq 1 ] && fatal "--check is incompatible with --dry-run"
    [ "${FORCE_REBUILD:-0}" -eq 1 ] && fatal "--check is incompatible with --force-rebuild"
    [ -f "$CHECK_FILE" ] || fatal "Manifest file not found: $CHECK_FILE"
    [ -r "$CHECK_FILE" ] || fatal "Manifest file not readable: $CHECK_FILE"
  fi

  # Ensure a target directory was provided (guard against set -u).
  # When CHECK_FILE is set, TARGET_DIR is optional (defaults to CWD).
  if [ -n "${CHECK_FILE:-}" ]; then
    if [ $# -ge 1 ]; then
      TARGET_DIR=$1
    else
      TARGET_DIR="$(pwd)"
    fi
  else
    if [ $# -lt 1 ]; then
      usage
      exit 1
    fi
    TARGET_DIR=$1
  fi
  [ -d "$TARGET_DIR" ] || fatal "Directory '$TARGET_DIR' not found."

  # Resolve STORE_DIR to absolute path if set
  if [ -n "${STORE_DIR:-}" ]; then
    case "$STORE_DIR" in
      /*) ;; # already absolute
      *) STORE_DIR="$(cd "$TARGET_DIR" 2>/dev/null && cd "$(dirname "$STORE_DIR")" 2>/dev/null && pwd -P)/$(basename "$STORE_DIR")" \
           || fatal "Cannot resolve --store-dir path: $STORE_DIR" ;;
    esac
  fi

  # -------------------------
  # Normalize and validate individual options
  # -------------------------

  # per-file algo validation: parse comma-separated list for multi-algo mode
  # (e.g. -a md5,sha256). Each element must be a supported algorithm.
  IFS=',' read -ra PER_FILE_ALGOS <<< "${PER_FILE_ALGO:-md5}"
  local _algo
  for _algo in "${PER_FILE_ALGOS[@]}"; do
    case "$_algo" in
      md5|sha1|sha224|sha256|sha384|sha512) ;;
      *) fatal "Unsupported per-file algo: $_algo (use md5, sha1, sha224, sha256, sha384, or sha512)" ;;
    esac
  done
  # Primary algorithm is always the first element (backward compatible)
  PER_FILE_ALGO="${PER_FILE_ALGOS[0]}"

  # Multi-algo conflict checks: comma-separated -a is incompatible with read-only modes
  if [ "${#PER_FILE_ALGOS[@]}" -gt 1 ]; then
    [ -n "${CHECK_FILE:-}" ] && fatal "Multi-algo (-a md5,sha256) is incompatible with --check"
    [ "${STATUS_ONLY:-0}" -eq 1 ] && fatal "Multi-algo (-a md5,sha256) is incompatible with --status"
    [ "${VERIFY_ONLY:-0}" -eq 1 ] && fatal "Multi-algo (-a md5,sha256) is incompatible with --verify-only"
  fi

  # meta signature algo must be sha256, md5, or none; default to sha256
  case "${META_SIG_ALGO:-sha256}" in
    sha256|md5|none) META_SIG_ALGO="${META_SIG_ALGO:-sha256}" ;;
    *) fatal "Unsupported meta sig algo: ${META_SIG_ALGO}" ;;
  esac

  # first-run choice must be one of skip | overwrite | prompt (if set)
  if [ -n "${FIRST_RUN_CHOICE:-}" ]; then
    case "$FIRST_RUN_CHOICE" in
      skip|overwrite|prompt) ;;
      *) fatal "Invalid -C/--first-run-choice: $FIRST_RUN_CHOICE (use skip|overwrite|prompt)" ;;
    esac
  fi

  # parallel jobs: integer, "auto" (all cores), or fraction (3/4, 2/3, 1/2, 1/4)
  if [ -n "${PARALLEL_JOBS:-}" ]; then
    case "$PARALLEL_JOBS" in
      auto)
        PARALLEL_JOBS=$(detect_cores)
        ;;
      [0-9]*/[0-9]*)
        # Fraction of cores: e.g. 3/4, 1/2
        local _num="${PARALLEL_JOBS%/*}"
        local _den="${PARALLEL_JOBS#*/}"
        if [ "${_den:-0}" -gt 0 ] && [ "${_num:-0}" -gt 0 ]; then
          local _cores
          _cores=$(detect_cores)
          PARALLEL_JOBS=$(( (_cores * _num + _den - 1) / _den ))  # round up
        else
          fatal "Invalid -p/--parallel fraction: $PARALLEL_JOBS"
        fi
        ;;
      ''|*[!0-9]*)
        fatal "Invalid -p/--parallel value: $PARALLEL_JOBS (use integer, 'auto', or fraction like 3/4)" ;;
      *)
        ;;
    esac
    [ "${PARALLEL_JOBS:-0}" -lt 1 ] && PARALLEL_JOBS=1
  else
    PARALLEL_JOBS="${PARALLEL_JOBS:-1}"
  fi

  # parallel dirs: integer, "auto" (all cores), or fraction (3/4, 1/2, 1/4)
  if [ -n "${PARALLEL_DIRS:-}" ]; then
    case "$PARALLEL_DIRS" in
      auto)
        PARALLEL_DIRS=$(detect_cores)
        ;;
      [0-9]*/[0-9]*)
        local _num="${PARALLEL_DIRS%/*}"
        local _den="${PARALLEL_DIRS#*/}"
        if [ "${_den:-0}" -gt 0 ] && [ "${_num:-0}" -gt 0 ]; then
          local _cores
          _cores=$(detect_cores)
          PARALLEL_DIRS=$(( (_cores * _num + _den - 1) / _den ))  # round up
        else
          fatal "Invalid -P/--parallel-dirs fraction: $PARALLEL_DIRS"
        fi
        ;;
      ''|*[!0-9]*)
        fatal "Invalid -P/--parallel-dirs value: $PARALLEL_DIRS (use integer, 'auto', or fraction like 3/4)" ;;
      *)
        ;;
    esac
    [ "${PARALLEL_DIRS:-0}" -lt 1 ] && PARALLEL_DIRS=1
  else
    PARALLEL_DIRS="${PARALLEL_DIRS:-1}"
  fi

  # log format must be text | json | csv
  case "${LOG_FORMAT:-text}" in
    text|json|csv) LOG_FORMAT="${LOG_FORMAT:-text}" ;;
    *) fatal "Invalid -o/--output format: $LOG_FORMAT (use text|json|csv)" ;;
  esac

  # max-size / min-size: convert human-readable values to bytes and cross-validate
  if [ -n "${MAX_SIZE:-}" ]; then
    MAX_SIZE_BYTES=$(to_bytes "$MAX_SIZE")
    [ -n "$MAX_SIZE_BYTES" ] && [ "$MAX_SIZE_BYTES" -gt 0 ] 2>/dev/null \
      || fatal "Invalid --max-size value: '$MAX_SIZE'"
  fi
  if [ -n "${MIN_SIZE:-}" ]; then
    MIN_SIZE_BYTES=$(to_bytes "$MIN_SIZE")
    [ -n "$MIN_SIZE_BYTES" ] && [ "$MIN_SIZE_BYTES" -gt 0 ] 2>/dev/null \
      || fatal "Invalid --min-size value: '$MIN_SIZE'"
  fi
  if [ "${MAX_SIZE_BYTES:-0}" -gt 0 ] && [ "${MIN_SIZE_BYTES:-0}" -gt 0 ] \
     && [ "$MIN_SIZE_BYTES" -gt "$MAX_SIZE_BYTES" ]; then
    fatal "--min-size ($MIN_SIZE) cannot exceed --max-size ($MAX_SIZE)"
  fi

  # -------------------------
  # Filenames derived from base names
  # -------------------------
  # Strip known algorithm extensions from BASE_NAME to prevent double-extension,
  # then derive sidecar names using the current PER_FILE_ALGO.
  BASE_NAME="${BASE_NAME%%.md5}"
  BASE_NAME="${BASE_NAME%%.sha[0-9]*}"
  SUM_FILENAME="${BASE_NAME}.${PER_FILE_ALGO}"
  # Multi-algo: derive one manifest filename per algorithm
  SUM_FILENAMES=()
  for _algo in "${PER_FILE_ALGOS[@]}"; do
    SUM_FILENAMES+=("${BASE_NAME}.${_algo}")
  done
  META_FILENAME="${BASE_NAME}.meta"
  LOG_BASE="${LOG_BASE:-$BASE_NAME}"
  LOG_FILENAME="${LOG_BASE}.log"
  
}
