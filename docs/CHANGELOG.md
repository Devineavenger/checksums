## [Unreleased]
## v4.1.2 - 2026-03-04

### Documentation
* docs: add exit codes section to `--help` output (0, 1, 2, 130, 143)

## v4.1.1 - 2026-03-04

### Fixes
* fix: add signal handler cleanup — `_orch_cleanup` trap on EXIT/INT/TERM removes orphaned temp files, temp directories, and FIFO semaphore on interrupt or crash

### Tests
* test: 4 new tests — `_orch_cleanup` temp file removal, temp directory removal, semaphore teardown, no-op safety

## v4.1.0 - 2026-03-04

### Features
* feat: parallel directory processing (`-P N` / `--parallel-dirs N`) — process up to N directories simultaneously with a shared FIFO semaphore pool of `-p` hash worker slots; dynamic workload balancing across directories of varying size
* feat: parallel planning — `decide_directories_plan()` dispatches directory analysis to parallel workers when `-p N` > 1, with ordered result aggregation
* feat: parallel first-run verification — `first_run_verify()` dispatches directory verification to parallel workers when `-p N` > 1 and choice is not `prompt`

### Changes
* chore: FIFO semaphore uses FD 7 (avoids conflicts with testing frameworks on FD 3)
* chore: directory-level PID pool (`DIR_PIDS`) separated from file-level (`HASH_PIDS`)

### Tests
* test: 17 new tests — parallel directory processing (7), parallel first-run verification (5), parallel planning (5)

## v4.0.0 - 2026-03-04

### Features
* feat: parallel verification — `emit_md5_file_details` now dispatches to parallel batch workers when `-p N` > 1, using the proven `_do_hash_batch` / `_par_wait_all` pattern; falls back to sequential when `-p 1`
* feat: incremental update — planner uses single `stat_all_fields` call (populates `STAT_CACHE` for processor reuse) and adds inode:dev comparison to catch file replacements where mtime+size are preserved
* feat: `-p` accepts `auto` (all CPU cores) and fractions (`3/4`, `1/2`, `1/4`, etc.) for CPU-based parallelism; `detect_cores()` added with portable detection (`nproc` / `sysctl` / `/proc/cpuinfo`)

### Changes
* chore: `STAT_CACHE` cleared at end of each `process_single_directory` to prevent unbounded memory growth
* chore: `-R` / `--no-reuse` help text clarified as safety valve for forced rehash (use with `-r` for full rebuild)

### Tests
* test: 18 new tests — parallel verification (5), incremental update with inode tracking (5), `detect_cores` (2), `-p auto`/fraction parsing (6)

## v3.9.12 - 2026-03-04

### Fixes
* fix: release.yml — add tag-push publish job for automatic GitHub Releases without re-running release.sh


## v3.9.11 - 2026-03-04

### Fixes
* fix: release.sh — guard against duplicate version headings in CHANGELOG

### Documentation
* docs: deduplicate v3.9.10 and v3.9.9 CHANGELOG headings


## v3.9.10 - 2026-03-03

### Changes
* chore: ci.yml — skip CI on "Release v" commits; tighten permissions to read-only; remove changelog-draft auto-commit job (side-effect prone); keep changelog preview as PR comment
* chore: test.yml — remove push/PR triggers (duplicated ci.yml); keep nightly-only schedule with strict mode; run full test suite via run-bats.sh instead of test_matrix.bats alone
* chore: release.yml — remove push trigger (caused CI tag loop and duplicate CHANGELOG entries); keep workflow_dispatch only

## v3.9.9 - 2026-03-03

### Fixes
* fix: Makefile — add user-reinstall to .PHONY; use --exclude '*-*' on git describe in changelog/changelog-draft targets so CI tags are never used as baseline; fix changelog-draft header format and guard against stacking duplicate [Unreleased] headers; add @ to dos2unix target; remove trailing tabs; add missing dos2unix and user-reinstall to help text
* fix: dos2unix.sh — remove *.swp (binary Vim swap files) and *.json (third-party bats packages) from conversion patterns; add *.md; exclude dist/ and tests/test_helper/ from all find expressions

## v3.9.8 - 2026-03-03

### Fixes
* fix: release.yml — skip release job when push commit message starts with "Release v"; prevents CI loop where make release push triggered the workflow again, producing a duplicate changelog entry and a spurious CI tag (e.g. v3.9.7-ci86)

## v3.9.7 - 2026-03-03

Automated CI release; no user-facing changes.

## v3.9.6 - 2026-03-03

### Fixes
* fix: resolve remaining codebase inconsistencies


## v3.9.5 - 2026-03-03

### Fixes
* fix: logging.sh — elevate emit_md5_detail "verified OK" from vlog to log so all MD5 detail results are at the same level (consistent with mismatch/missing)
* fix: process.sh — demote per-file "DRYRUN: would hash" from log to vlog (prevents per-file console spam at scale); add directory-level DRYRUN summary at log level so the marker remains visible without verbose
* fix: orchestrator.sh — replace echo with log/vlog in preview section so folder counts go to run log and respect JSON/CSV format; individual folder lines demoted to vlog
* fix: first_run.sh — demote DRYRUN simulated-action messages from log to vlog in overwrite and prompt branches for consistency; add missing vlog in prompt-branch dry-run path

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

### Fixes
* fix: release.sh — record PREV_TAG before new tag is created; use --exclude '*-*' so CI tags (v3.9.x-ciN) are never used as the commit baseline; auto-changelog and grouped notes now always reference the correct previous release
* fix: Makefile — replace echo -n with printf for POSIX portability; add missing closing quote on addheaders-recursive help line

## v3.9.2 - 2026-03-02

### Changes
* chore: release.sh — auto-populate [Unreleased] from conventional commits when section is empty; no manual changelog commit needed before make release

## v3.9.1 - 2026-03-02

### Fixes
* fix: args.sh — add pre-scan loop before getopts so config file is loaded before CLI flags are parsed; CLI flags now always override config values

### Tests
* test: test_orchestrator.bats — call parse_args before run_checksums in config-override test to match corrected execution order; add usage.sh and args.sh loads

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

## v3.8.7 - 2025-11-26

## v3.8.5 - 2025-11-26

## v3.8.4 - 2025-11-26

## v3.8.3 - 2025-11-26

## v3.8.1 - 2025-11-26

## v3.7.16 - 2025-11-26

## v3.7.15 - 2025-11-26

## v3.7.14 - 2025-11-26

## v3.7.13 - 2025-11-26

## v3.7.12 - 2025-11-26

## v3.7.11 - 2025-11-26

## v3.7.10 - 2025-11-26

## v3.7.9 - 2025-11-26

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

## v2.5.19 - 2025-10-19

## v2.5.18 - 2025-10-19

## v2.5.17 - 2025-10-19

## v2.5.16 - 2025-10-19
