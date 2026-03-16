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
# Version: 5.3.0
#
# init.sh
#
# Initialization for checksums (modular architecture).
#
# Responsibilities:
# - Define base paths, version string, and entrypoint name.
# - Set all configurable defaults (can be overridden via config or CLI).
# - Declare and initialize cross-module globals so ShellCheck recognizes them.
# - Document new features: skip empty directories and root sidefile protection.
#
# Key features:
# - SKIP_EMPTY=1: planner and processor skip directories that contain no regular files anywhere below them.
# - NO_ROOT_SIDEFILES=1: root TARGET_DIR will not get per-dir sidecar files (.md5/.meta/.log) by default.
#   Use --allow-root-sidefiles to opt in to sidefiles in root.
#
set -euo pipefail
shopt -s nullglob

# BASE_DIR points at the project root (one level up from lib/)
# This works both for local checkout (./lib) and system installs (/usr/local/share/checksums/lib).
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Determine version string (VER)
# Lookup order (robust and mirrors uninstall.sh behavior):
# 1) Prefer on-disk VERSION at $BASE_DIR/VERSION (installed package)
# 2) Fallback: a "Version: X.Y.Z" comment in a nearby checksums.sh (source checkout)
# 3) Fallback: a "Version: X.Y.Z" comment in the invoking wrapper (e.g., /usr/local/bin/checksums)
# 4) Final fallback: the literal on this line (kept for safety)
#
# This makes the runtime behave sensibly whether run from a checkout or an installed prefix.
determine_VER() {
  local vfile verline caller candidate

  # 1) Installed VERSION file (preferred)
  vfile="$BASE_DIR/VERSION"
  if [ -r "$vfile" ]; then
    # read whole file, trim trailing whitespace/newline
    local content
    content="$(<"$vfile")"
    # Trim trailing whitespace/newline
    printf '%s' "${content%"${content##*[![:space:]]}"}"
    return 0
  fi

  # 2) Look for Version: comment in a nearby checksums.sh (source checkout)
  if [ -r "$BASE_DIR/../checksums.sh" ]; then
    verline="$(sed -n '1,20p' "$BASE_DIR/../checksums.sh" 2>/dev/null | grep -i '^# *Version:' || true)"
    if [ -n "$verline" ]; then
      printf '%s' "$(echo "$verline" | sed -E 's/^# *Version:[[:space:]]*//I')"
      return 0
    fi
  fi

  # 3) Look for Version: comment in the invoking wrapper (if there is one)
  # When init.sh is sourced from an installed wrapper, $0 will normally point at that wrapper.
  # Fall back to common install location if $0 is not helpful.
  caller="${0:-}"
  if [ -n "$caller" ] && [ -r "$caller" ]; then
    verline="$(sed -n '1,20p' "$caller" 2>/dev/null | grep -i '^# *Version:' || true)"
    if [ -n "$verline" ]; then
      printf '%s' "$(echo "$verline" | sed -E 's/^# *Version:[[:space:]]*//I')"
      return 0
    fi
  fi

  # 3b) Also try common installed wrapper path relative to typical prefix if above failed
  if [ -r "/usr/local/bin/checksums" ]; then
    verline="$(sed -n '1,20p' /usr/local/bin/checksums 2>/dev/null | grep -i '^# *Version:' || true)"
    if [ -n "$verline" ]; then
      printf '%s' "$(echo "$verline" | sed -E 's/^# *Version:[[:space:]]*//I')"
      return 0
    fi
  fi

  # 4) Final fallback: hard-coded literal (kept for compatibility)
  printf '%s' "5.3.0"
}

# Populate VER using the robust lookup
VER="$(determine_VER)"

# Executable name for usage output
ME="$(basename "$0")"

# === Defaults (override via config, CLI, or environment) ===
# NOTE: use parameter expansion so exported environment variables can
# override these defaults (CI/test ergonomics) while CLI flags still win.
: "${BASE_NAME:=#####checksums#####}"          # Base name for sidecar files (.md5, .meta, .log)
: "${PER_FILE_ALGO:=md5}"                      # md5 (default) or sha256
: "${META_SIG_ALGO:=sha256}"                   # sha256 (default), md5, or none
: "${LOG_BASE:=}"                              # Base name for per-dir logs; defaults to BASE_NAME if not set
: "${DRY_RUN:=0}"                              # -n simulate actions without writing files
: "${DEBUG:=0}"                                # -d debug verbosity (repeatable)
: "${VERBOSE:=0}"                              # -v verbose logging
: "${YES:=0}"                                  # -y assume yes (skip confirmation)
: "${ASSUME_NO:=0}"                            # --assume-no (force prompt decline)
: "${FORCE_REBUILD:=0}"                        # -r force recomputation ignoring manifests
: "${FIRST_RUN:=0}"                            # -F first-run verification/bootstrap mode
: "${FIRST_RUN_CHOICE:=prompt}"                # -C skip | overwrite | prompt (on mismatch)
: "${PARALLEL_JOBS:=1}"                        # -p N parallel hashing jobs
: "${PARALLEL_DIRS:=1}"                        # -P N parallel directory processing
: "${LOG_FORMAT:=text}"                        # -o text (default), json, csv
: "${VERIFY_ONLY:=0}"                          # -V audit only (no writes)
: "${STATUS_ONLY:=0}"                          # -S status/diff mode (read-only)
: "${CONFIG_FILE:=}"                           # --config FILE explicit config path
: "${VERIFY_MD5_DETAILS:=1}"                   # When non-zero, planner will run per-directory md5 verification on .md5-only dirs and emit MISSING/MISMATCH lines into the run log (enabled by default). Use --md5-details / -z to explicitly toggle; default = 1
: "${BATCH_RULES:=0-10M:20,10M-40M:20,>40M:5}"   # -b | --batch Adaptive batching defaults. Format string: "LOW-HIGH:COUNT,LOW-HIGH:COUNT,>HIGH:COUNT" Units: suffix K/M/G supported (e.g. 2M = 2 megabytes). Default: 0–10M → 20 files, 10M–40M → 20 files, >40M → 5 files
: "${FIRST_RUN_KEEP:=0}"                       # Preserve first-run log after overwrites when set (CLI or env). Default off: delete the stale log post-overwrite.

# Progress reporting: on by default, use -Q / --no-progress to suppress
: "${PROGRESS:=1}"

# Minimal mode: write only .md5 manifest, skip .meta/.log/.run.log and first-run logic
: "${MINIMAL:=0}"

# Quiet mode: suppress all output except errors
: "${QUIET:=0}"

# Central manifest store: redirect all sidecar files into STORE_DIR (mirror tree layout)
: "${STORE_DIR:=}"

# File size filter thresholds: skip files outside the specified range
# Values accept human-readable sizes: plain bytes, K, M, G, T (e.g., 10M, 1G, 500K)
: "${MAX_SIZE:=}"       # --max-size SIZE : skip files larger than SIZE
: "${MIN_SIZE:=}"       # --min-size SIZE : skip files smaller than SIZE
MAX_SIZE_BYTES=0        # parsed byte value (0 = no limit)
MIN_SIZE_BYTES=0        # parsed byte value (0 = no limit)

# Symlink handling: when enabled, find(1) uses -L to follow symbolic links.
# Symlinked files are included in manifests and symlinked directories are descended into.
# Default off: safer, avoids potential loops, matches traditional find behavior.
: "${FOLLOW_SYMLINKS:=0}"

# External manifest check mode: verify files against an external manifest file
# (sha256sum -c / md5sum -c interop). Set via -c FILE / --check FILE.
# When non-empty, main() dispatches to run_check_mode() instead of run_checksums().
: "${CHECK_FILE:=}"

# Tracks whether the user explicitly passed -a / --per-file-algo on the CLI.
# Used by check mode to decide whether to auto-detect algorithm from manifest extension.
# 0 = PER_FILE_ALGO is the default; 1 = user explicitly set it.
_ALGO_EXPLICIT=0

# === New features (v3.x) ===
# Skip empty/container-only directories (planner + processor): on by default
: "${SKIP_EMPTY:=1}"

# Disable reuse heuristics (new flag -R / --no-reuse)
: "${NO_REUSE:=0}"

# Root sidefile protection (no per-dir .md5/.meta/.log in root by default): on by default
# Pass --allow-root-sidefiles to disable protection and allow sidefiles in root.
: "${NO_ROOT_SIDEFILES:=1}"

# === Multi-algorithm support ===
# Arrays of algorithms and manifest filenames. Single-element arrays when one
# algorithm is specified (identical to legacy behavior). Populated fully by
# parse_args after comma-separated -a parsing; seeded here with the default.
PER_FILE_ALGOS=("$PER_FILE_ALGO")
SUM_FILENAMES=("${BASE_NAME}.${PER_FILE_ALGO}")

# === Filenames derived from base names (set once globally) ===
SUM_FILENAME="${BASE_NAME}.${PER_FILE_ALGO}"
META_FILENAME="${BASE_NAME}.meta"
LOG_FILENAME="${LOG_BASE:-$BASE_NAME}.log"

# === Filenames (secondary) ===
: "${LOCK_SUFFIX:=.lock}"

# === Color variable defaults (overridden by color.sh when loaded via loader) ===
# Declared here so modules work safely under set -u even when color.sh is not sourced
# (e.g. in test harnesses that load individual modules directly).
: "${_C_BOLD:=}" "${_C_DIM:=}" "${_C_RST:=}"
: "${_C_RED:=}" "${_C_GREEN:=}" "${_C_YELLOW:=}" "${_C_BLUE:=}"
: "${_C_MAGENTA:=}" "${_C_CYAN:=}" "${_C_WHITE:=}"

# === Exclusions (patterns to skip when scanning a directory) ===
SUM_EXCL="" META_EXCL="" LOG_EXCL="" LOCK_EXCL=""

# === Tool detection flags (set in detect_tools) ===
TOOL_md5_cmd=""                   # md5sum or md5 -r
TOOL_sha256=""                    # sha256sum
TOOL_shasum=""                    # shasum -a 256
TOOL_stat_gnu=0                   # GNU stat detected (1) vs BSD (0)
TOOL_flock=0                      # flock availability: 1/0

# === Semaphore state (parallel directory processing) ===
SEM_FIFO=""                                    # FIFO path for shared worker pool
SEM_FD=""                                      # File descriptor for semaphore

# === Logging state (globals declared for ShellCheck visibility) ===
declare -g RUN_LOG=""             # Path to run-level log
declare -g LOG_FILEPATH=""        # Current log file being written
declare -g FIRST_RUN_LOG=""       # Path to detailed first-run log

# === Error collection and log level (globals) ===
declare -ga errors=()             # Collected error messages
declare -g log_level=1            # Default console logging level

# === Summary counters (globals) ===
declare -g count_verified=0       # Directories verified OK
declare -g count_processed=0      # Total directories processed (legacy)
declare -g count_created=0        # Directories with new manifests created
declare -g count_verified_existing=0  # Directories with existing manifests verified
declare -g count_skipped=0        # Directories skipped
declare -g count_overwritten=0    # Directories overwritten (first-run scheduling)
declare -g count_errors=0         # Errors encountered
declare -g count_read_errors=0    # Files skipped due to read errors (permission denied, vanished)
declare -g count_files_hashed=0   # Files newly hashed (not reused)
declare -g count_files_reused=0   # Files reused from cache (unchanged since last run)
declare -g bytes_hashed=0         # Total bytes of newly hashed files
declare -g bytes_reused=0         # Total bytes of reused files

# === Run ID (audit trail) ===
RUN_ID=$(uuidgen 2>/dev/null || printf '%s-%s-%s' "$(date +%s)" "$$" "$RANDOM")

# === Associative arrays for meta (declare if supported) ===
# Avoid scalar assignments that would convert arrays; initialize as empty maps.
if declare -p -A >/dev/null 2>&1; then
  # shellcheck disable=SC2154,SC2034
  declare -gA meta_hash_by_path meta_mtime meta_size meta_inode_dev meta_path_by_inode 2>/dev/null || true
  declare -gA meta_hash_by_path=() meta_mtime=() meta_size=() meta_inode_dev=() meta_path_by_inode=()
  # scheduled-first-run lookup (assoc)
  declare -gA first_run_overwrite_set 2>/dev/null || true
  declare -gA first_run_overwrite_set=()
else
  # fallback text-map file (created lazily)
  MAP_first_run_overwrite=""
fi

# Ensure first_run_overwrite array exists for first_run.sh usage
first_run_overwrite=()
