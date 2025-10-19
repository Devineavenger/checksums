#!/usr/bin/env bash
# shellcheck disable=SC2034
# Version: 3.0.0
#
# init.sh
#
# Initialization for checksums v3.0 (split from checksums.sh v2.12.5).
#
# Modular checksum manager with parallel + inode incremental hashing
#
# v2.1: summary report, structured logs, log rotation
# v2.2: verification-only mode (-V), audit trail with run ID
# v2.3: config file support, skip/include patterns, non-interactive modes, 2-log rotation
# v2.3.1: --config FILE option and default <BASE_NAME>.conf
# v2.4: cross-platform stat abstraction, Bash 3.2 fallback for associative arrays
# v2.7 (custom): print pre-processing summary before confirmation and side effects.
# v2.8 (custom): added count_processed and included it in final summary.
# v2.9 (custom): added quick preview planner to show immediate list before heavy checks.
# v2.10 (custom): defer first_run_verify until after preview and user confirmation.
# v2.11 (custom): first_run_verify is non-destructive and schedules overwrites; orchestrator performs them.
# v3.0 (custom): skip empty directories, root sidefile protection, planner/processor/logging updated.
#
# New configuration (v3.0):
# - SKIP_EMPTY (default 1) — directories containing zero regular files are skipped during planning and processing.
# - NO_ROOT_SIDEFILES (default 1) — the root TARGET_DIR will not receive per-directory sidecar files (.md5/.meta/.log).
#   Only the run-level log remains in root. Use --allow-root-sidefiles to opt-in to sidefiles in root.
#
set -euo pipefail
shopt -s nullglob

# BASE_DIR points at the project root (one level up from lib/)
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="$(cat "$BASE_DIR/VERSION" 2>/dev/null || echo "2.4.0")"
ME="$(basename "$0")"

# === Defaults (can be overridden by config file or CLI) ===
BASE_NAME="#####checksums#####"   # Base name for generated files (.md5, .meta, .log)
PER_FILE_ALGO="md5"               # Algorithm for per-file checksums: "md5" (default) or "sha256"
META_SIG_ALGO="sha256"            # Algorithm for meta signature: "sha256" (default), "md5", or "none"
LOG_BASE=""                       # Base name for run logs; defaults to BASE_NAME if not set
DRY_RUN=0                         # If 1, simulate actions without writing files (-n)
DEBUG=0                           # Debug verbosity level (-d, repeatable)
VERBOSE=0                         # Verbose logging (-v)
YES=0                             # Auto-confirm prompts (-y or --assume-yes)
ASSUME_NO=0                       # Auto-decline prompts (--assume-no)
FORCE_REBUILD=0                   # Force rebuild of checksums, ignoring manifests (-r)
FIRST_RUN=0                       # First-run verification mode (-F)
FIRST_RUN_CHOICE="prompt"         # Action on mismatch in first-run: "skip", "overwrite", or "prompt" (-C)
PARALLEL_JOBS=1                   # Number of parallel hashing jobs (-p N)
LOG_FORMAT="text"                 # Log output format: "text" (default), "json", or "csv" (-o)
VERIFY_ONLY=0                     # Verification-only audit mode (-V); no writes, just checks
CONFIG_FILE=""                    # explicit config file path (--config FILE)

# === New: Skip empty directories flag (v3.0) ===
SKIP_EMPTY=1

# === New: Prevent sidecar files in root (v3.0+) ===
# Default set to 1: the base TARGET_DIR will not get .md5/.meta/.log.
# Only the run-level log (<LOG_BASE>.run.log) will be created in root.
NO_ROOT_SIDEFILES=1

# === Filenames derived from base names (set once globally) ===
MD5_FILENAME="${BASE_NAME}.md5"
META_FILENAME="${BASE_NAME}.meta"
LOG_FILENAME="${LOG_BASE:-$BASE_NAME}.log"

# === Filenames (secondary) ===
LOCK_SUFFIX=".lock"               # Suffix for transient lock files

# === Exclusions (patterns to skip when scanning a directory) ===
MD5_EXCL="" META_EXCL="" LOG_EXCL="" LOCK_EXCL=""

# === Tool detection flags (set in detect_tools) ===
TOOL_md5_cmd=""                   # Command for md5 (md5sum or md5 -r)
TOOL_sha256=""                    # Command for sha256sum
TOOL_shasum=""                    # Command for shasum -a 256
TOOL_stat_gnu=0                   # retained for compatibility with older modules (not used in 2.4)
TOOL_flock=0                      # 1 if flock is available, else 0

# === Logging state (globals; declared for shellcheck visibility) ===
declare -g RUN_LOG=""             # Path to run-level log
declare -g LOG_FILEPATH=""        # Current log file being written
declare -g FIRST_RUN_LOG=""       # Path to first-run verification log

# === Errors and log level (globals; declared for shellcheck visibility) ===
declare -ga errors=()             # Array of error messages collected during run
declare -g log_level=1            # Default log verbosity level

# === Summary counters (globals; declared for shellcheck visibility) ===
declare -g count_verified=0       # Directories verified OK
declare -g count_processed=0      # Directories processed (had processing run)
declare -g count_skipped=0        # Directories skipped (up-to-date)
declare -g count_overwritten=0    # Directories overwritten/rebuilt
declare -g count_errors=0         # Errors encountered

# === Run ID for audit trail (2.2+) ===
RUN_ID=$(uuidgen 2>/dev/null || date +%s$$)

# Ensure associative meta_* arrays are declared only when supported.
if declare -p -A >/dev/null 2>&1; then
  # shellcheck disable=SC2154,SC2034
  declare -gA meta_hash_by_path meta_mtime meta_size meta_inode_dev meta_path_by_inode 2>/dev/null || true
  declare -gA meta_hash_by_path=() meta_mtime=() meta_size=() meta_inode_dev=() meta_path_by_inode=()
fi
