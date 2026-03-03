#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# usage.sh
#
# Prints CLI usage, grouped by category and aligned with args.sh parsing.

usage() {
  cat <<EOF
$ME Version $VER

Quick Start (no flags):
  Running "checksums DIRECTORY" with no options will:
    - Use md5 for per-file hashes and sha256 for meta signatures
    - Create sidecar files: #####checksums#####.md5, #####checksums#####.meta, #####checksums#####.log
    - Skip empty or container-only directories (SKIP_EMPTY=1 by default)
    - Keep the root DIRECTORY clean (NO_ROOT_SIDEFILES=1 by default)
    - Reuse existing hashes when files are unchanged
    - Run single-threaded (PARALLEL_JOBS=1)
    - Prompt for confirmation before processing
    - Write a run log: #####checksums#####.run.log

Usage: $ME [options] DIRECTORY

General Options:
  -h, --help         show this help
  --version          show version and exit
  --config FILE      load configuration from FILE (overrides default)

File Naming Options:
  -f NAME, --base-name NAME
                     base name for sidecar files (.md5/.meta/.log) [default: ${BASE_NAME}]
  -l LOGNAME, --log-base LOGNAME
                     log base name (default: same as -f)

Hashing Options:
  -a ALGO, --per-file-algo ALGO
                     per-file checksum algorithm: md5 (default) or sha256
  -m ALGO, --meta-sig ALGO
                     meta signature algorithm: sha256 (default), md5, or none
  -R, --no-reuse     disable reuse heuristics; always recompute file hashes
  -p N, --parallel N number of parallel hashing jobs (default 1)
  -b RULES, --batch RULES
                     adaptive batching rules (default: "0-1M:20,1M-40M:20,>40M:1")
                     format: "LOW-HIGH:COUNT,>HIGH:COUNT" with K/M/G suffixes

Run Control Options:
  -n, --dry-run      dry-run (no writes)
  -d, --debug        increase debug verbosity (repeatable)
  -v, --verbose      increase verbosity (repeatable)
  -r, --force-rebuild
                     force rebuild (ignore manifests)
  -y, --assume-yes   assume "yes" for all prompts (non-interactive)
  --assume-no        assume "no" for all prompts (non-interactive)

First-run Options:
  -F, --first-run    bootstrap mode: verify existing .md5 files lacking .meta/.log
  -C CHOICE, --first-run-choice CHOICE
                     first-run choice: skip | overwrite | prompt (default prompt)
  -K, --first-run-keep
                     Keep the first-run log after overwrites (audit trail).
                     Default: delete stale first-run log post-overwrite.

+Environment: FIRST_RUN_KEEP=1 is equivalent to --first-run-keep.

Verification Options:
  -V, --verify-only  audit mode (no writes)
  -z, --no-md5-details
                     disable per-directory md5 verification in planning
  --md5-details      enable md5 verification in planning (default)

Directory Handling Options:
  --skip-empty       skip directories with no files (default)
  --no-skip-empty    process empty/container-only directories too
  --allow-root-sidefiles
                     allow sidecar files (.md5/.meta/.log) in root DIRECTORY
                     (default: root sidefiles disabled)

Logging Options:
  -o FORMAT, --output FORMAT
                     log format: text (default), json, csv

Config file:
  By default, the tool looks for "<BASE_NAME>.conf" in the root DIRECTORY.
  With default BASE_NAME ("#####checksums#####"), this is "#####checksums#####.conf".
  Use --config FILE to specify an alternate path.
  CLI arguments always override config settings.

Patterns:
  INCLUDE_PATTERNS, EXCLUDE_PATTERNS accept shell globs (e.g., "*.tmp").
  If INCLUDE_PATTERNS is non-empty, only matching files are considered.

Quick Examples:
  $ME -a sha256 -o json --assume-yes /data/project
  $ME --config /data/project/custom.conf -V /data/project
  $ME --allow-root-sidefiles /data/project
  $ME -F -C overwrite /data/project

Common Usage Patterns:

1. First-run Bootstrap (initialize meta/logs from existing .md5 files)
   $ME -F -C overwrite -a md5 -m sha256 -p 4 --md5-details --skip-empty /data/project
   -F enables first-run mode: verifies existing .md5 manifests that lack .meta/.log
   -C overwrite ensures mismatched manifests are recomputed automatically
   -a md5 keeps parity with legacy .md5 format
   -m sha256 secures meta signatures
   -p 4 uses 4 parallel hashing jobs (baseline for modern CPUs)
   --md5-details logs per-file MISSING/MISMATCH diagnostics
   --skip-empty avoids sidecars in empty/container-only folders
   Behavior:
     * Existing .md5 files are verified
     * Missing or invalid .meta/.log files are scheduled for creation
     * Mismatched checksums are overwritten (unless directory is empty)
     * Produces a detailed first-run log: #####checksums#####.first-run.log
     * Root stays clean unless you add --allow-root-sidefiles

2. Verify-only Audit (check integrity without writing anything)
   $ME -V -a md5 -m sha256 -p 4 --md5-details --skip-empty --assume-yes /data/project
   -V enables verify-only mode: no writes, only integrity checks
   -a md5 / -m sha256 match defaults; verification works regardless
   -p 4 parallelizes hashing for faster audits
   --md5-details emits per-file diagnostics (VERIFIED/MISMATCH/MISSING)
   --skip-empty ignores empty/container-only directories
   --assume-yes skips confirmation prompt (non-interactive)
   Behavior:
     * Reads existing .md5 and .meta manifests
     * Verifies file hashes against manifests
     * Reports VERIFIED, MISMATCH, or MISSING in run log
     * Does not create or modify any sidecar files
     * Ideal for CI/CD pipelines or scheduled audits

3. Dry-run Planning (preview what would happen without changes)
   $ME -n -a sha256 -m sha256 -p 4 -v --md5-details --skip-empty --assume-yes /data/project
   -n enables dry-run mode: simulate all steps without writing sidecars
   -a sha256 / -m sha256 test production algorithms during rehearsal
   -p 4 shows realistic parallel hashing plan
   -v increases verbosity for detailed preview
   --md5-details surfaces per-file verification details
   --skip-empty avoids noise from empty/container-only directories
   --assume-yes skips prompt for automation
   Behavior:
     * Quick preview lists to-process vs skipped directories
     * Accurate planning checks meta signatures, file counts, newer-file detection
     * Logs "would hash" messages and decisions without creating .md5/.meta/.log
     * Perfect for validating config files, exclude/include patterns, and batch rules safely
EOF
}
