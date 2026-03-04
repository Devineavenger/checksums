## [Unreleased]

### Features
* feat: minimal mode (`-M` / `--minimal`) — hash-only mode that writes only the `.md5` manifest file; skips `.meta`, `.log`, `.run.log`, lock files, first-run logic, meta signatures, and log rotation; compatible with `md5sum`/`sha256sum` output format; configurable via `MINIMAL=1` in config

### Tests
* test: 7 new tests — `-M` flag parsing, `--minimal` long flag, `.md5`-only output, hash format validation, `FIRST_RUN=0` forcing, `write_meta` no-op, `verify_meta_sig` bypass

## v4.5.0 - 2026-03-05

### Features
* feat: live progress reporting — per-file `[dirs] [files] ETA: Xm Ys  dirname` progress line on stderr with dynamic column widths (scales to 100M+ dirs/files); ETA computed from elapsed time and files completed; enabled by default on TTY, suppressed via `-Q` / `--no-progress` / `PROGRESS=0`; shared counter file for parallel accuracy; no memory growth

### Tests
* test: 7 new tests — `_progress_init` setup, `_progress_file_done` increment, suppression when `PROGRESS=0`, suppression when zero files, `_progress_cleanup`, `_format_eta` formatting, no-op when inactive

## v4.4.1 - 2026-03-04

### Fixes
* fix: remove 10 duplicate tests across `test_helpers.bats`, `test_integrations.bats`, and `test_planner_extra.bats` (173 tests remain across 30 files)

### Changes
* chore: comment audit — removed stale version references from `checksums.sh`, `init.sh`, `install.sh`, `process.sh`; removed orphaned cleanup note from `process.sh`; added missing context comments in `orchestrator.sh`, `hash.sh`, `tools.sh`; standardized `md5f` → `sumf` variable naming in `process.sh`
* chore: retroactively populated empty changelog entries for v2.4, v2.6, v2.7, and v3.0.0 from removed source comments

## v4.4.0 - 2026-03-04

### Features
* feat: safe key=value config parser — `_load_config()` replaces shell-sourced `.conf` files with a line-by-line key=value parser; no code execution; strips comments, blank lines, and matching quotes; maps 25 known keys to globals; unknown keys produce a warning; old bash array syntax detected and rejected with migration hint

### Changes
* chore: `example/checksums.conf` — rewritten for key=value format with all 25 configurable keys documented; old v2.3 template preserved as `checksums.conf.v2.3`

### Tests
* test: 13 new tests — `_load_config` string/integer/quoted parsing, comment/blank handling, whitespace around `=`, unknown key warning, old array syntax detection, empty values, special characters, multi-key parsing, invalid line warning

## v4.3.0 - 2026-03-04

### Features
* feat: global color system — new shared `lib/color.sh` module with 10-variable palette (bold, dim, reset, red, green, yellow, blue, magenta, cyan, white); TTY detection and `NO_COLOR` support; auto-sourced before all other modules
* feat: colored logging — ERROR prefix in red, VERBOSE/DEBUG output dimmed; INFO unchanged; colors apply to text format only (JSON/CSV unaffected); log files never colored
* feat: colored orchestrator — summary counts colored by category (green processed, yellow skipped, red errors, magenta counts); preview counts colored; interactive prompts bold; completion message green
* feat: colored planner — `PLAN: skip` in yellow, `PLAN: process` in green (verbose output)
* feat: colored process — `DRYRUN:` prefix in yellow, `Verify-only:` prefix in cyan, META signature results colored
* feat: colored first-run prompts — bold prompt text, dim input hint
* feat: colored help text — all section headings bold via `--help`

### Changes
* refactor: status.sh — removed local `_status_use_color`/`_status_init_colors`, replaced `_C_NEW`/`_C_DEL`/`_C_MOD` with shared `_C_GREEN`/`_C_RED`/`_C_YELLOW` from color.sh
* chore: init.sh — color variable defaults (empty strings) declared for `set -u` safety when color.sh is not loaded (test harnesses)
* chore: run-bats.sh — increase `CI_PARALLEL` default from 4 to 32 for faster test execution

### Tests
* test: 6 new tests — `_color_init` variable population, `NO_COLOR` clearing, idempotency, empty `NO_COLOR`, escape sequence format, auto-init at source time

## v4.2.0 - 2026-03-04

### Features
* feat: status/diff mode (`-S` / `--status`) — read-only diff against existing manifests showing new (A), deleted (D), modified (M), and unchanged files per directory; color-coded output with TTY detection and `NO_COLOR` support; exits 0 if clean, 1 if changes found (CI-friendly)
* feat: stat-based fast path — compares mtime, size, and inode:dev from `.meta` without rehashing; use `-R` to force hash verification of stat-changed files

### Changes
* chore: status mode respects `SKIP_EMPTY` but still checks directories with manifests (catches all-files-deleted case)
* chore: `--status` is mutually exclusive with `--dry-run`, `--force-rebuild`, and `--first-run`

### Tests
* test: 18 new tests — status classification (11), run_status integration (4), args parsing (3)

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

### Features
* feat: modular architecture — monolithic `checksums.sh` v2.12.5 split into `lib/` modules (`init.sh`, `loader.sh`, `planner.sh`, `orchestrator.sh`, `process.sh`, `hash.sh`, `logging.sh`, `meta.sh`, `stat.sh`, `fs.sh`, `args.sh`, `usage.sh`, `tools.sh`, `compat.sh`)
* feat: `SKIP_EMPTY` (default 1) — skip creating .meta/.log/.md5 for empty or container-only directories; early-return in `process_single_directory` before any side effects
* feat: `NO_ROOT_SIDEFILES` (default 1) — block sidecar file creation in root TARGET_DIR

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

## v2.7 — date not recorded

### Changes
* chore: side-effect-free planning function for pre-summary
* chore: skip logging moved out of the decision loop (skip logs happen after confirmation in `run_checksums`)

## v2.6 — date not recorded

### Fixes
* fix: signature stability — pass meta lines to `write_meta` as individual args (not one giant string)
* fix: syntax — fix mismatched braces in DRY_RUN block
* fix: robustness — initialize arrays in `process_directories` to avoid unbound variable errors

## v2.4 — date not recorded

### Changes
* refactor: switched from `get_inode`/`get_dev`/`get_mtime`/`get_size` to `stat_field` (unified abstraction)
* feat: added compatibility path for Bash < 4 using text-map fallbacks when associative arrays are not available
