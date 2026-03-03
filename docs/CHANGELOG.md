## [Unreleased]

### Fixes
* fix: logging.sh — elevate emit_md5_detail "verified OK" from vlog to log so all MD5 detail results are at the same level (consistent with mismatch/missing)
* fix: process.sh — demote per-file "DRYRUN: would hash" from log to vlog (prevents per-file console spam at scale); add directory-level DRYRUN summary at log level so the marker remains visible without verbose
* fix: orchestrator.sh — replace echo with log/vlog in preview section so folder counts go to run log and respect JSON/CSV format; individual folder lines demoted to vlog
* fix: first_run.sh — demote DRYRUN simulated-action messages from log to vlog in overwrite and prompt branches for consistency; add missing vlog in prompt-branch dry-run path

## v3.9.4 - 2026-03-03

## v3.9.4 - 2026-03-03

### Fixes
* fix: compat.sh — use grep -F for all key lookups in map_set/map_get/map_del to prevent directory paths with regex metacharacters (e.g. '.') from causing wrong matches
* fix: first_run.sh — remove no-op count_overwritten+0 line in SKIP_EMPTY overwrite branch
* fix: release.sh — add how-to comment explaining correct changelog pre-write workflow

### Tests
* test: test_integrations.bats — create file.txt in setup to fix file_hash on non-existent file; remove duplicate RUN_LOG reset lines
* test: test_edgecases.bats — rename test to accurately describe verify_meta_sig behaviour (passes with no signature line)
* test: test_units.bats — add missing status checks between multiple run calls in normalize_unit tests

## v3.9.3 - 2026-03-02

## v3.9.3 - 2026-03-02

### Fixes
* fix: release.sh — record PREV_TAG before new tag is created; exclude CI tags from baseline

### Documentation
* docs: changelog for v3.9.3


## v3.9.3 - 2026-03-02

### Fixes
* fix: release.sh — record PREV_TAG before new tag is created; use --exclude '*-*' so CI tags (v3.9.x-ciN) are never used as the commit baseline; auto-changelog and grouped notes now always reference the correct previous release
* fix: Makefile — replace echo -n with printf for POSIX portability; add missing closing quote on addheaders-recursive help line

## v3.9.2 - 2026-03-02

## v3.9.2 - 2026-03-02

### Documentation
* docs: changelog for v3.9.2

### Chores
* chore: auto-generate changelog from commits when [Unreleased] is empty


## v3.9.2 - 2026-03-02

### Changes
* chore: release.sh — auto-populate [Unreleased] from conventional commits when section is empty; no manual changelog commit needed before make release

## v3.9.1 - 2026-03-02

## v3.9.1 - 2026-03-02

## v3.9.1 - 2026-03-02

### Fixes
* fix: args.sh — add pre-scan loop before getopts so config file is loaded before CLI flags are parsed; CLI flags now always override config values

### Tests
* test: test_orchestrator.bats — call parse_args before run_checksums in config-override test to match corrected execution order; add usage.sh and args.sh loads

## v3.9.0 - 2026-03-02

## v3.9.0 - 2026-03-02

## v3.9.0 - 2026-03-02

### Fixes
* fix: stat.sh — split STAT_FLAG from format string; stat fields are now clean integers with no leading whitespace
* fix: process.sh — flush last partial batch to worker before waiting; all files in a directory are now hashed in parallel
* fix: process.sh — open-ended batch rules (>HIGH:N) now stored and matched correctly in classify_batch_size
* fix: args.sh — remove duplicate -b: entry in getopts optstring
* fix: orchestrator.sh — re-sync RUN_LOG after config may override BASE_NAME/LOG_BASE; no orphaned log files
* fix: orchestrator.sh — remove dead log-redirect block inside root guard (RUN_LOG was always empty there)
* fix: process.sh — _proc_cleanup now removes results_dir and no longer references undefined results_file

### Tests
* test: test_stats.bats — stat_field and stat_all_fields return pure integers with no leading whitespace
* test: test_process_extra.bats — classify_batch_size fixed/open-ended/fallback rule coverage; partial-batch hashing correctness; temp dir cleanup
* test: test_orchestrator.bats — run log uses correct name when config overrides BASE_NAME

## v3.8.9 - 2025-11-26

## v3.8.9 - 2025-11-26

## v3.8.7 - 2025-11-26

## v3.8.7 - 2025-11-26

## v3.8.5 - 2025-11-26

## v3.8.5 - 2025-11-26

## v3.8.4 - 2025-11-26

## v3.8.4 - 2025-11-26

## v3.8.3 - 2025-11-26

## v3.8.3 - 2025-11-26

## v3.8.1 - 2025-11-26

## v3.8.1 - 2025-11-26

## v3.7.16 - 2025-11-26

## v3.7.16 - 2025-11-26

## v3.7.15 - 2025-11-26

## v3.7.15 - 2025-11-26

## v3.7.14 - 2025-11-26

## v3.7.14 - 2025-11-26

## v3.7.14 - 2025-11-26

## v3.7.14 - 2025-11-26

## v3.7.13 - 2025-11-26

## v3.7.13 - 2025-11-26

## v3.7.13 - 2025-11-26

## v3.7.12 - 2025-11-26

## v3.7.12 - 2025-11-26

## v3.7.11 - 2025-11-26

## v3.7.11 - 2025-11-26

## v3.7.10 - 2025-11-26

# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

## v3.2.2 - 2025-10-19

## v3.2.1 - 2025-10-19

## v3.2.0 - 2025-10-19

## v3.1.2 - 2025-10-19

## v3.0.0 - 2025-10-19

## v2.12.5 - 2025-10-19

## v2.12.4 - 2025-10-19

## v2.12.3 - 2025-10-19

## v2.12.2 - 2025-10-19

## v2.12.1 - 2025-10-19

## v2.12.0 - 2025-10-19

## v2.5.25 - 2025-10-19

## v2.5.24 - 2025-10-19

## v2.5.23 - 2025-10-19

## v2.5.22 - 2025-10-19

## v2.5.21 - 2025-10-19

## v2.5.20 - 2025-10-19

## v2.5.20 - 2025-10-19

## v2.5.19 - 2025-10-19

## v2.5.18 - 2025-10-19

## v2.5.18 - 2025-10-19

## v2.5.17 - 2025-10-19

## v2.5.16 - 2025-10-19




## v3.7.9 - 2025-11-26
