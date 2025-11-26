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
#   MD5_FILENAME, META_FILENAME, LOG_FILENAME
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

parse_args() {
  # NOTE: Global defaults (BASE_NAME, LOG_BASE, LOG_FORMAT, VERIFY_ONLY, ASSUME_NO,
  # CONFIG_FILE, FIRST_RUN_KEEP, VERIFY_MD5_DETAILS, etc.) are declared and
  # initialized in lib/init.sh. This function should only parse CLI options and
  # apply overrides. Do not re-declare global defaults here to avoid surprising
  # overrides and to keep a single source of truth for runtime defaults.
  # -------------------------
  # getopts setup
  # -------------------------
  # The optstring lists short options. Options that take an argument are followed
  # by ':' (e.g., f:). The trailing '-:' enables the getopts long-option hack:
  # when a long option is encountered, getopts sets opt='-' and OPTARG to the
  # long option name; we handle it in the '-' branch below.
  #
  # Short flags included: f a m l n d v r R F C z p b o y V h K
  while getopts "f:a:m:l:ndvrRFC:p:b:o:yVhKzb:-:" opt 2>/dev/null; do
    case "$opt" in
      # -------------------------
      # Short options (legacy)
      # -------------------------
      # Each short option mirrors a long option handled below. Keep comments
      # describing the semantic effect so maintainers can map short->long easily.
      f) BASE_NAME=$OPTARG ;;            # -f BASE_NAME : base name for .md5/.meta/.log
      a) PER_FILE_ALGO=$OPTARG ;;        # -a md5|sha256 : per-file checksum algorithm
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
      b) BATCH_RULES=$OPTARG ;;          # -b RULES : adaptive batching rules string
      o) LOG_FORMAT=$OPTARG ;;           # -o FORMAT : text | json | csv
      y) YES=1 ;;                        # -y : assume-yes (non-interactive)
      V) VERIFY_ONLY=1 ;;                # -V : verify-only audit mode (no writes)
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
          verify-only)
            VERIFY_ONLY=1
            ;;
          allow-root-sidefiles)
            # Affirmative: allow sidecar files (.md5/.meta/.log) in root (default is protected)
            NO_ROOT_SIDEFILES=0
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
  BATCH_RULES="${BATCH_RULES:-0-2M:20,2M-50M:10,>50M:1}"

  # Validate BATCH_RULES format: comma-separated "LOW-HIGH:COUNT" or ">HIGH:COUNT"
  # Accept optional K/M/G suffixes. If invalid, record a warning and fall back.
  if ! [[ "$BATCH_RULES" =~ ^([0-9]+[KMG]?-[0-9]+[KMG]?:[0-9]+,)*([0-9]+[KMG]?-[0-9]+[KMG]?:[0-9]+|>[0-9]+[KMG]?:[0-9]+)$ ]]; then
    record_error "Invalid --batch/-b rules format: '$BATCH_RULES'. Falling back to default."
    BATCH_RULES="0-2M:20,2M-50M:10,>50M:1"
  fi

  # Ensure a target directory was provided (guard against set -u)
  if [ $# -lt 1 ]; then
    usage
    exit 1
  fi

  TARGET_DIR=$1
  [ -d "$TARGET_DIR" ] || fatal "Directory '$TARGET_DIR' not found."

  # -------------------------
  # Normalize and validate individual options
  # -------------------------

  # per-file algo must be md5 or sha256; default to md5 if unset
  case "${PER_FILE_ALGO:-md5}" in
    md5|sha256) PER_FILE_ALGO="${PER_FILE_ALGO:-md5}" ;;
    *) fatal "Unsupported per-file algo: ${PER_FILE_ALGO}" ;;
  esac

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

  # parallel jobs must be a positive integer (if set); otherwise default to 1
  if [ -n "${PARALLEL_JOBS:-}" ]; then
    case "$PARALLEL_JOBS" in
      ''|*[!0-9]*) fatal "Invalid -p/--parallel value (must be integer)" ;;
      *) [ "$PARALLEL_JOBS" -lt 1 ] && PARALLEL_JOBS=1 ;;
    esac
  else
    PARALLEL_JOBS="${PARALLEL_JOBS:-1}"
  fi

  # log format must be text | json | csv
  case "${LOG_FORMAT:-text}" in
    text|json|csv) LOG_FORMAT="${LOG_FORMAT:-text}" ;;
    *) fatal "Invalid -o/--output format: $LOG_FORMAT (use text|json|csv)" ;;
  esac

  # -------------------------
  # Filenames derived from base names
  # -------------------------
  # Preserve original behavior: strip trailing .md5 if present and derive sidecar names.
  # This ensures tests and downstream code can rely on consistent filenames.
  BASE_NAME="${BASE_NAME%%.md5}"
  MD5_FILENAME="${BASE_NAME}.md5"
  META_FILENAME="${BASE_NAME}.meta"
  LOG_BASE="${LOG_BASE:-$BASE_NAME}"
  LOG_FILENAME="${LOG_BASE}.log"
  
}
