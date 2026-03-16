## [Unreleased]

## v5.2.0 - 2026-03-16

### Features
* feat: symlink handling flags (`-L` / `--follow-symlinks` / `--no-follow-symlinks`) — explicit control over symbolic link traversal during file and directory discovery; default off (matches prior behavior: symlinks not followed); when enabled, symlinked files are included in manifests and symlinked directories are descended into; `_find()` wrapper in `fs.sh` centralizes `-L` injection for all 13 core `find` calls across 6 modules (`fs.sh`, `planner.sh`, `orchestrator.sh`, `status.sh`, `first_run.sh`); `FOLLOW_SYMLINKS` config key in `_load_config()`; broken symlinks silently skipped (find -L + `-type f` naturally excludes dangling links); compatible with all modes (`--status`, `--check`, `--verify-only`, etc.)

### Tests
* test: new `tests/test_symlinks.bats` — 10 tests covering default non-following behavior for files and directories, `-L` and `--follow-symlinks` file/directory following, `--no-follow-symlinks` override (last flag wins), broken symlink handling, config file support, status mode with `-L`, verify-only mode with `-L`

## v5.1.0 - 2026-03-16

### Features
* feat: multi-algorithm single pass (`-a md5,sha256`) — hash files once per algorithm in a single run, writing one manifest per algorithm (e.g. `.md5` and `.sha256`); comma-separated `-a` flag and `PER_FILE_ALGO` config key; OS page cache amortizes sequential per-algo reads; `.meta` stores primary (first) algo hash only; reuse disabled for multi-algo (v1); incompatible with `--check`, `--status`, `--verify-only`; `check_required_tools()` validates all requested algorithms; `build_exclusions()` and `find_file_expr()` exclude all manifest filenames; planner schedules directory if any manifest is missing; new `_do_hash_batch_multi()` batch worker in `hash.sh`; usage/man page updated with multi-algo syntax and example

### Tests
* test: new `tests/test_multi_algo.bats` — 17 tests covering two-algo and three-algo manifest creation with hash correctness verification, `.meta` primary hash storage, backward compatibility (single algo), invalid algo rejection, conflict detection with `--check`/`--status`/`--verify-only`, manifest filename exclusion from scanning, planner scheduling on missing manifest, dry-run output, config file support, minimal mode

## v5.0.0 - 2026-03-13

### Features
* feat: man page generation — `docs/checksums.1.in` roff template with `%%VERSION%%`/`%%DATE%%` placeholders; `make man` generates `docs/checksums.1` via sed substitution; `make man-preview` renders in terminal; covers all 10 option categories (General, File Naming, Hashing, Run Control, First-run, Verification, Status, Directory Handling, File Filtering, Logging), CONFIGURATION, PATTERNS, EXAMPLES (5 common usage patterns), EXIT STATUS, FILES, ENVIRONMENT, SEE ALSO, AUTHOR, COPYRIGHT sections
* feat: man page integrated into install/uninstall — `make install`/`make uninstall` and `scripts/install.sh`/`scripts/uninstall.sh` handle `$PREFIX/share/man/man1/checksums.1`; `scripts/release.sh` auto-regenerates man page with updated version at release time

## v4.13.0 - 2026-03-12

### Features
* feat: external manifest check mode (`-c FILE` / `--check FILE`) — sha256sum -c / md5sum -c interop; reads GNU format (`hash  filename`) and BSD format (`ALGO (file) = hash`); auto-detects algorithm from manifest extension (`.md5`, `.sha256`, etc.); `-a` overrides auto-detection; optional `DIRECTORY` argument sets base path for relative filenames (defaults to CWD); `-q` suppresses OK lines; `-p N` enables parallel verification; summary warnings on stderr; exit 0 if all OK, exit 1 on any failure; new `CHECK_FILE` config key; conflict detection with `--status`, `--verify-only`, `--first-run`, `--dry-run`, `--force-rebuild`

### Tests
* test: new `tests/test_check_mode.bats` — 25 tests covering basic OK/FAILED/missing/unreadable output, algorithm auto-detection and override, BSD format, quiet mode, summary warnings, path resolution (relative, CWD default, `./` prefix), edge cases (empty manifest, comments/blank lines), parallel verification, conflict detection, short/long flag parity
* test: permission tests now run under root — replaced `runuser -u nobody` with directory-replacement technique (file → directory causes "Is a directory" error even for root); removed `_run_func_as_nobody` helper; affects `file_hash returns 2 for unreadable file`, `read_meta handles unreadable meta gracefully`, `-c: unreadable file produces FAILED open or read`

## v4.12.1 - 2026-03-11

### Refactor
* refactor: extract verification functions from `logging.sh` into new `lib/verification.sh` module — `emit_md5_detail`, `emit_md5_file_details`, `_verify_md5_sequential`, `_verify_md5_parallel`
* refactor: remove dead `_do_hash_task()` from `hash.sh` (superseded by `_do_hash_batch`)
* refactor: rename `_to_bytes()` → `to_bytes()` in `fs.sh` to reflect cross-module public API usage

### Tests
* test: add `lib/verification.sh` sourcing-sanity test; update test loads for new module split

## v4.12.0 - 2026-03-11

### Features
* feat: graceful permission/read error handling — unreadable or vanished files are skipped from manifests with clear warnings instead of silently writing blank hashes; `file_hash()` returns exit code 2 for read errors; batch workers communicate errors via `ERROR:` sentinel; verification distinguishes `UNREADABLE` from `MISMATCH` in run log; `read_meta()` guards against unreadable meta files; summary reports `count_read_errors`

### Tests
* test: 12 new tests — `file_hash` error return codes, `_do_hash_batch` ERROR sentinel, `process_single_directory` with vanished files, manifest integrity (no blank hashes), mixed readable/vanished files, sequential verification UNREADABLE detection, `read_meta` permission handling

## v4.11.0 - 2026-03-11

### Features
* feat: file size filtering via `--max-size SIZE` and `--min-size SIZE` — skip files larger or smaller than a threshold; accepts human-readable sizes (e.g., `10M`, `1G`, `500K`, plain bytes); applied in `find_file_expr`, `has_files`, and `has_local_files`; configurable via `MAX_SIZE` / `MIN_SIZE` in config; cross-validated (min cannot exceed max)

### Tests
* test: 10 new tests — `find_file_expr` with MAX/MIN/both, `has_files`/`has_local_files` size gating, integration tests for `--max-size`/`--min-size` CLI flags, combined with `--exclude`, config file support, invalid cross-validation rejection

## v4.10.2 - 2026-03-10

### Fixes
* fix: parallel-safe test teardown — removed aggressive `/tmp/tmp.*` scan from `test_short_vs_long_flags` teardown that was deleting other parallel tests' temp directories mid-execution, causing sporadic exit code mismatches under `bats --jobs`
* fix: replaced future timestamps (year 2030) with fixed past timestamps (year 2000) in `test_status` and `test_incremental` to avoid time-bomb test failures
* fix: backdate sidecar files instead of data files in `test_incremental` to preserve planner's `-newer` fast-path detection
* fix: scoped leaked temp dir check to test's own `$TMPDIR` in `test_process_extra` instead of global `/tmp`

## v4.10.1 - 2026-03-10

### Performance
* perf: test suite runs ~3.3× faster — parallel test file execution via `bats --jobs` (auto-detects CPU count, requires GNU parallel); replaced 5 `sleep 1` calls with `touch -t` forced timestamps in `test_status`, `test_matrix`, and `test_incremental`

### Fixes
* fix: parallel-safe test suite — renamed `TMPDIR` to `TEST_DIR` in integration tests (`test_matrix`, `test_short_vs_long_flags`) to prevent env var leakage into checksums.sh subprocesses during parallel bats runs; snapshot-based leaked temp dir check in `test_process_extra` avoids false positives from concurrent tests

## v4.10.0 - 2026-03-09

### Features
* feat: file filtering via `--exclude PATTERN` / `-e PATTERN` and `--include PATTERN` / `-i PATTERN` — basename glob matching, repeatable flags, comma-separated values supported; include acts as allowlist (only matching files processed); exclude takes precedence over include; config file equivalents `EXCLUDE_PATTERNS` and `INCLUDE_PATTERNS` (comma-separated)

### Fixes
* fix: `_load_config()` now properly splits comma-separated `EXCLUDE_PATTERNS` and `INCLUDE_PATTERNS` values into individual array elements instead of assigning the entire string as a single element
* fix: `EXCLUDE_PATTERNS` / `INCLUDE_PATTERNS` array declaration bug — `declare -a arr=` (empty RHS) created a single empty-string element instead of an empty array, causing `${arr:+1}` guard checks to fail and skip all pattern filtering; replaced with `declare -ga` and proper empty-array initialization
* fix: `has_files()` and `has_local_files()` now respect `INCLUDE_PATTERNS` — previously only checked `EXCLUDE_PATTERNS`, so directories with only non-matching files would be scheduled for processing and produce empty manifests

### Tests
* test: 22 new tests — 4 config comma-splitting tests (`test_config.bats`), 18 pattern filtering tests (`test_patterns.bats`) covering `find_file_expr`, `has_files`, `has_local_files` unit tests plus integration tests for `--exclude`, `--include`, `-e`, `-i`, comma-separated values, repeatable flags, tool-file exclusion immunity, config+CLI accumulation, and filenames with spaces

## v4.9.2 - 2026-03-09

### Fixes
* fix: variable declaration bug in `usage()` — bare `R` after command substitution was executed as a command instead of declared as a variable, causing `R: command not found` on every `--help` / no-args invocation

### Changes
* change: default `BATCH_RULES` raised from `0-1M:20,1M-40M:20,>40M:1` to `0-10M:20,10M-40M:20,>40M:5` — wider first bucket (10 MB vs 1 MB) and larger batch for big files (5 vs 1)

### Tests
* test: 21 new tests (`test_usage.bats`) — `--help` and `--version` clean output, `usage()` direct call, all 17 `lib/*.sh` files sourced individually and via loader to catch variable declaration and syntax errors at source time

## v4.9.1 - 2026-03-05

### Fixes
* fix: version not displayed during `make user-install` / `make user-reinstall` — greedy prefix trim in `install.sh` could strip entire version string

## v4.9.0 - 2026-03-05

### Features
* feat: central manifest store (`-D DIR` / `--store-dir DIR`) — redirect all sidecar files (`.md5`/`.sha256`, `.meta`, `.log`) into a central directory with mirrored tree layout; keeps source directories clean; run log and first-run log also redirected into store root; detects existing scattered sidefiles and prompts to migrate or leave in place; configurable via `STORE_DIR` in config; `_sidecar_path()` and `_runlog_path()` helpers centralize all path resolution

### Tests
* test: 11 new tests — `-D` and `--store-dir` flag parsing, `_sidecar_path` with/without store dir, root directory mapping, `_runlog_path` with/without store dir, store subdirectory creation, config key, `build_exclusions` store-dir exclusion inside/outside target

## v4.8.0 - 2026-03-05

### Features
* feat: quiet mode (`-q` / `--quiet`) — suppress all console output except errors; sets `log_level=0` and disables progress; file logging unaffected; configurable via `QUIET=1` in config

### Tests
* test: 4 new tests — `-q` flag parsing, `--quiet` long flag, INFO suppression, fatal output preserved

## v4.7.0 - 2026-03-05

### Features
* feat: algorithm-based manifest filenames — manifest extension now matches `PER_FILE_ALGO` (`.md5`, `.sha256`, `.sha1`, etc.); supports md5, sha1, sha224, sha256, sha384, sha512; `file_hash()` generalized for any SHA variant via `${algo}sum` or `shasum -a N` fallback; variable rename `MD5_FILENAME` → `SUM_FILENAME`, `MD5_EXCL` → `SUM_EXCL` across codebase

### Tests
* test: 7 new tests — default md5 manifest, sha256 manifest, sha1 manifest, `SUM_FILENAME` derivation after `parse_args -a sha256`, `parse_args -a sha512`, `file_hash` with sha512, unsupported algo rejection

## v4.6.0 - 2026-03-05

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

### Changes
* chore: mirror first-run MISSING/MISMATCH findings to the main run log (`RUN_LOG`) in `first_run.sh`, so verification results are visible without `-K`
* chore: demote verbose orchestrator messages to `vlog` — `NO_REUSE` notice, `Run ID`, summary counters for verified/created manifests
* chore: demote process.sh messages to appropriate log levels — sidecar path listing to `dbg`, "no candidate files" and "skipped writing manifests" to `vlog`
* chore: reduce `user-reinstall` sleep from 1s to 0.3s in Makefile

### Tests
* test: add `-K` / `--first-run-keep` to short-vs-long flag parity matrix; relax `-l` log-base assertion

## v3.8.7 - 2025-11-26

### Changes
* chore: demote internal DEBUG-level orchestrator messages from `log` to `dbg` — scheduled overwrite cleanup, first-run log lifecycle messages now require `-d` to appear on console

## v3.8.5 - 2025-11-26

### Changes
* refactor: rewrite `rotate_log()` in logging.sh — replaced fragile GNU/BSD `stat` + `awk` + `xargs` pipeline with `mapfile` + lexicographic sort on timestamp-embedded filenames; platform-independent (no `stat` parsing); added debug output for rotation candidates and survivors; per-file `rm` with diagnostic fallback on failure
* chore: demote orchestrator `process_single_directory` entry log to `vlog`; demote process.sh `LOG_FILEPATH set` message to `dbg`

## v3.8.4 - 2025-11-26

Release automation; no user-facing changes.

## v3.8.3 - 2025-11-26

### Fixes
* fix: defer run-log creation in `run_checksums()` until `TARGET_DIR` is validated and normalized — prevents accidental run log creation in the current working directory or repository root when `TARGET_DIR` is unset (e.g. in test harnesses); run log now only created if target directory exists and is writable

## v3.8.1 - 2025-11-26

### Features
* feat: first-run-keep flag (`-K` / `--first-run-keep` / `FIRST_RUN_KEEP=1`) — preserve the first-run log after scheduled overwrites for audit purposes; default behavior now deletes the stale first-run log post-overwrite; controlled via CLI flag or environment variable

### Changes
* refactor: move global variable initialization from `parse_args()` to `lib/init.sh` — `parse_args()` no longer re-declares `LOG_BASE`, `LOG_FORMAT`, `VERIFY_ONLY`, `ASSUME_NO`, `CONFIG_FILE`, `VERIFY_MD5_DETAILS`; single source of truth for runtime defaults
* chore: Makefile `clean` target now removes only `.tar.gz` files inside `dist/` instead of deleting the entire directory

### Tests
* test: first-run log lifecycle — assert log is removed by default after overwrites; assert log is preserved with `-K` flag and `FIRST_RUN_KEEP=1` environment variable

## v3.7.16 - 2025-11-26

### Fixes
* fix: root-guard test now handles CI runners that cannot write to `/` — falls back to asserting refusal message in stdout when run log file is absent

## v3.7.15 - 2025-11-26

### Changes
* chore: release.sh dirty-tree guard — stage any post-rebase changes detected after `git stash pop` to keep the release commit consistent

## v3.7.14 - 2025-11-26

### Fixes
* fix: orchestrator root-guard now writes refusal run log to `$PWD` instead of attempting to write into `/` (which fails on most systems); redirect `RUN_LOG` to safe location when `TARGET_DIR=/`

### Changes
* chore: release.sh auto-stash — automatically stash dirty working tree (including untracked files) before syncing with `origin/main` via rebase; restore stash after successful rebase

## v3.7.13 - 2025-11-26

### Changes
* chore: vendor bats-support helper instead of submodule

## v3.7.12 - 2025-11-26

### Changes
* chore: vendor bats-support as full directory tree (replacing git submodule) for reproducible test helper resolution
* fix: orchestrator root-guard now writes refusal message to `$RUN_LOG` so tests can assert on it

## v3.7.11 - 2025-11-26

### Changes
* chore: release.sh CI tag fallback — when remote tag already exists and `FORCE_TAG_UPDATE` is not set, create a unique CI tag (`v$VER-ci$N` / `v$VER-sha$HASH` / `v$VER-$TIMESTAMP`) instead of failing; use `TAG_TO_USE` throughout push and GitHub release payload

## v3.7.10 - 2025-11-26

### Changes
* chore: Makefile `clean` target rewrite — consolidated scattered `find -delete` calls into grouped, verbose `find -print -exec rm` invocations with descriptive echo headers; added `.build/` cleanup; lock directory removal now uses two-pass approach (rmdir then rm -rf)

## v3.7.9 - 2025-11-26

### Changes
* chore: release.sh auto-version from VERSION file — when no version argument is provided, reads from `VERSION` file or derives next patch version from latest git tag; replaces hard-coded usage error with intelligent fallback
* chore: release.sh CHANGELOG promotion rewrite — use `awk index()` instead of regex delimiters to avoid unterminated-regexp issues; insert fresh `[Unreleased]` header at top via `BEGIN` block; `END` block appends version heading if `[Unreleased]` was not found

## v3.7.8 - 2025-11-26

### Changes
* docs: move CONTRIBUTING.md and CHANGELOG.md into docs/

## v3.7.7 - 2025-11-26

### Changes
* chore(tests): vendor bats-support test helper into tests/test_helper

## v3.7.6 - 2025-11-25

### Changes
* refactor: move scripts to `scripts/` directory — `release.sh`, `install.sh`, `uninstall.sh` relocated; Makefile updated to reference `scripts/` paths for all user-install, release, and dist targets
* chore: add `scripts/license-tool.sh` for license header automation; new Makefile targets `newfile`, `addheader`, `addheaders`, `addheaders-recursive`
* chore: add `scripts/debug_run.sh` (debug wrapper) and `scripts/run_with_instrument.sh` (profiling wrapper)
* refactor: Makefile rewrite — fix `ci` target dependency (`tests` instead of `test`), add license header targets, add positional arg support for FILE/DIR, embedded LICENSE_HEADER definition, consistent indentation
* refactor: expanded comments throughout `args.sh` — documented getopts hack, short-to-long option mapping, defensive initialization rationale

### Tests
* test: add `tests/test_short_vs_long_flags.bats` — parity tests for all short/long CLI flag pairs
* test: vendor bats-assert submodule into `tests/test_helper/`

## v3.7.5 - 2025-11-25

### Features
* feat: `--no-skip-empty` flag — disable default skip-empty behavior to process empty/container-only directories

### Changes
* refactor: convert all global defaults in `init.sh` from direct assignment to parameter expansion (`: "${VAR:=default}"`) — allows environment variable overrides for CI/test ergonomics while CLI flags still win
* chore: add `tests/run-bats.sh` wrapper script for bats execution with CI-configurable parallelism; Makefile `tests` target now uses it

### Tests
* test: add `tests/test_matrix.bats` — integration test matrix covering dry-run, verify-only, force-rebuild, skip-empty, allow-root-sidefiles, parallel, first-run, and per-file algo combinations

## v3.7.4 - 2025-11-24

### Changes
* chore: unconditional stale-lock purge at `process_single_directory` entry — remove sidecar lock files (`.md5.lock`, `.meta.lock`, `.log.lock`) deterministically before processing, with debug output for removed paths
* chore: `LOCK_SUFFIX` initialization changed to parameter expansion (`: "${LOCK_SUFFIX:=.lock}"`) for override safety

### Tests
* test: add `tests/test_process_extra.bats` — 7 tests covering container-only directory skipping, verify-only empty/missing scenarios, dry-run sidecar suppression, stale lock removal, `cleanup_leftover_locks`, and missing directory error handling

## v3.7.3 - 2025-11-24

### Fixes
* fix: verify-only mode now distinguishes container-only directories (no local files, no manifest) from directories with files but a missing manifest — container-only dirs are skipped without error; files-present-but-no-manifest dirs produce an appropriate error

### Changes
* refactor: expanded module-level and function-level comments throughout `process.sh` — added high-level overview, adaptive batching rationale, backwards-compatibility notes, Bash < 4 fallback documentation

## v3.7.2 - 2025-11-24

### Features
* feat: split summary counter `count_processed` into `count_created` (new manifests) and `count_verified_existing` (existing verified) for more granular summary reporting

### Fixes
* fix: guard incremental hash reuse against empty hash values — both inode-based and path-based reuse paths now check `[ -n "$h" ]` before marking `reuse=1`, preventing blank hashes from propagating into manifests
* fix: verify-only mode now uses `emit_md5_file_details`/`emit_md5_detail` for proper per-file verification output instead of a simple pass/fail check
* fix: manifest post-write sanity check — scan for malformed lines (missing hash before filename) and recompute+repair in place; fallback hash computation during manifest assembly when `path_to_hash` entry is empty

## v3.7.1 - 2025-11-24

### Performance
* perf: replace `awk '{print $1}'` with `cut -d' ' -f1` in `file_hash()` for hash extraction — lighter-weight external process
* perf: replace `date -u` calls with Bash builtin `printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1` in all logging functions — eliminates 5 `date` forks per log call
* perf: replace `basename "$fpath"` with `${fpath##*/}` parameter expansion in `process_single_directory` — avoids external process per file
* perf: replace 4x `awk -F'\t'` stat field extraction with single `IFS=$'\t' read -r` in `process_single_directory` — eliminates 4 forks per file
* perf: add local per-directory stat cache (`_local_stat_cache`) in `process_single_directory` to avoid repeated `stat_all_fields` calls for the same file path

## v3.6.9 - 2025-11-23

### Performance
* perf: fs.sh — `_to_bytes()` results cached in `TO_BYTES_CACHE` associative array to avoid repeated subprocess calls during batch threshold lookups
* perf: logging.sh — `vlog()` and `dbg()` now short-circuit with level check before calling `_global_log()`, avoiding function call overhead when verbose/debug is disabled
* perf: stat.sh — `stat_all_fields()` results cached in `STAT_CACHE` associative array; subsequent calls for the same file return instantly; `detect_stat()` now uses feature probes (`stat -c %i .` / `stat -f %i .`) instead of `--version` check, with a `fallback` style for unknown platforms

### Fixes
* fix: process.sh — `classify_batch_size()` input sanitized (strip non-digits, default to 0); threshold key validation added to skip malformed entries; multiple `[ "$var" -eq ... ]` comparisons replaced with arithmetic `(( ))` context to prevent "integer expression expected" errors on empty operands
* fix: process.sh — `NO_REUSE` normalized once at loop start to avoid repeated empty-string checks; result collection guards all associative array lookups with `:-` defaults
* fix: process.sh — removed stale flush-last-batch block (redundant with `_par_wait_all`)

## v3.6.8 - 2025-11-23

### Fixes
* fix: fs.sh — quote variable in `bytes_from_unit()` suffix extraction to prevent glob expansion (`${val#$num}` -> `${val#"$num"}`)
* fix: process.sh — Bash < 4 `BATCH_THRESHOLDS` fallback changed from empty string to empty array to avoid type mismatch

### Tests
* test: `test_planner_extra.bats` — added missing module loads; setup now creates valid meta via `process_single_directory()` for realistic planner tests; fixed hidden-dir test to use directory instead of file; fixed meta-verified assertion logic
* test: `test_robustness.bats` — added missing module loads; refactored space-in-filename test to use NUL-safe loop; refactored many-file test to assert on sidefile content rather than log message
* test: `test_tools_extra.bats` — rewrote shasum fallback test with isolated `PATH` subshell and sanity assertions for reliable detection

## v3.6.7 - 2025-11-19

### Features
* feat: portable unit conversion — new `normalize_unit()`, `bytes_from_unit()`, and `_to_bytes()` helpers in `fs.sh`; accept human-readable sizes (K/KB/KiB/M/MB/MiB/G/T/P/E) with `numfmt` preferred and pure-bash fallback; replaces inline `numfmt` calls in batch threshold parsing

### Fixes
* fix: process.sh — `BATCH_THRESHOLDS` declaration hardened for both Bash >= 4 (proper `-gA` with type check) and Bash < 4 (array fallback + `THRESHOLDS_LIST` string); `init_batch_thresholds()` rewritten with robust parsing, input validation, and whitespace trimming; open-ended rules (`>HIGH:COUNT`) now stored as `"high_bytes-"` key instead of `">high_bytes"`
* fix: process.sh — `classify_batch_size()` now handles both associative array and `THRESHOLDS_LIST` fallback paths correctly
* fix: tools.sh — `detect_tools()` refactored: `sha256sum` and `shasum` are now mutually exclusive (shasum only selected when sha256sum absent); paths stored via `command -v` for reliability

### Changes
* chore: Makefile — fix help text typo (`make test` -> `make tests`)

### Tests
* test: new `test_edgecases.bats` (4 tests), `test_modes.bats` (3 tests), `test_planner_extra.bats` (3 tests), `test_robustness.bats` (2 tests), `test_tools_extra.bats` (2 tests), `test_units.bats` (8 tests) — covering batch thresholds, verify-only/dry-run modes, planner edge cases, filenames with spaces, shasum fallback, and unit conversion
* test: `test_integrations.bats` — removed duplicate `verify_md5_file` test (moved to `test_first_run.bats`)

## v3.6.6 - 2025-11-18

### Fixes
* fix: fs.sh — uncomment and activate safe default exclusion globals (`MD5_EXCL`, `META_EXCL`, `LOG_EXCL`, etc.) so helpers work under `set -u` without requiring `build_exclusions()` to run first
* fix: fs.sh — `has_files()` and `has_local_files()` now use exclusion variables instead of raw filenames for consistent filtering
* fix: fs.sh — `find_file_expr()` lock exclusion changed from `$LOCK_EXCL` to `*${LOCK_SUFFIX}` glob for broader match
* fix: orchestrator.sh — `run_checksums()` returns 1 instead of calling `fatal()`/`exit` on system root, allowing tests to assert on the error

### Changes
* chore: move `test_parallel.sh` and `time.txt` into `tests/parallel-speed/` subdirectory (not part of bats suite)
* chore: process.sh — guard meta cache transfer with length check and `:-` defaults to prevent unbound variable errors under `set -u`

### Tests
* test: 10 new test files — `test_first_run.bats`, `test_fs.bats`, `test_hash.bats`, `test_logging.bats`, `test_meta.bats`, `test_orchestrator.bats`, `test_planner.bats`, `test_process.bats`, `test_stats.bats`, `test_tools.bats` — establishing foundational unit test coverage across all lib modules

## v3.6.5 - 2025-11-18

### Fixes
* fix: first_run.sh — `verify_md5_file()` GNU format parser now uses parameter expansion instead of `awk` for filename extraction, correctly handling filenames with leading `*` (binary mode indicator) and multiple spaces

### Tests
* test: new `tests/test_integrations.bats` — 7 integration tests covering `verify_md5_file` multi-file/missing/malformed, `emit_md5_file_details` MISSING/MISMATCH logging, `SKIP_EMPTY` enforcement, `NO_ROOT_SIDEFILES` guard
* test: `test_helpers.bats` — 3 new tests for `verify_md5_file` multi-file, missing-file (rc=2), and malformed-manifest (rc=1) cases

## v3.6.4 - 2025-11-18

### Fixes
* fix: init.sh — `RUN_ID` fallback now includes `$$` and `$RANDOM` for uniqueness when `uuidgen` is unavailable (was `date +%s$$` which could collide)
* fix: process.sh — `init_batch_thresholds()` now checks for `numfmt` availability via `TOOL_numfmt` before calling it, preventing errors on systems without GNU coreutils

### Changes
* chore: tools.sh — detect `numfmt` in `detect_tools()` and set `TOOL_numfmt` flag; include in debug output

## v3.6.3 - 2025-11-18

### Fixes
* fix: process.sh — correct `sh -c` argument passing in locked meta removal (`$0` -> `$1` with explicit `sh` as argv[0])

## v3.6.2 - 2025-11-18

### Fixes
* fix: logging.sh — log rotation now works on both GNU and BSD/macOS `stat` (added `stat -f '%m %N'` fallback path)
* fix: fs.sh — `build_exclusions()` no longer adds bare `ALT_LOG_EXCL` to exclude patterns, preventing false exclusion of user files whose names happen to start with the log base
* fix: first_run.sh — Bash 3.x compatibility for `first_run_verify()`: added space-delimited string fallback when associative arrays are unavailable
* fix: meta.sh — `read_meta()` guarded with Bash version check; skips associative array population on Bash < 4 instead of crashing
* fix: planner.sh — replaced slow `find | xargs sh -c test -nt` per-file freshness check with native `find -newer` for faster planning

### Changes
* chore: stat.sh — restore `stat_field()` single-field wrapper alongside `stat_all_fields()` for backward compatibility with planner callers; restore individual format string globals (`STAT_INODE`, `STAT_DEV`, etc.)
* chore: process.sh — acquire flock before removing invalid meta file to prevent TOCTOU race with concurrent runs

## v3.6.1 - 2025-11-18

### Performance
* perf: stat.sh — combine four per-file `stat` calls (inode/dev/mtime/size) into a single invocation via `stat_all_fields()` with colon-delimited format; reduces subprocess overhead in hot paths
* perf: orchestrator.sh — replace per-directory file count loop with single-pass `find | tr | wc` pipeline for faster preview totals
* perf: process.sh — precompute batch thresholds once per run (`init_batch_thresholds()`) to avoid repeated `numfmt` conversions; use `stat_all_fields()` instead of four `stat_field()` calls per file

### Fixes
* fix: compat.sh — add fallback default for `BASH_VERSINFO[0]` to prevent unbound variable error on non-standard shells
* fix: compat.sh — `map_get()` missing `else` branch caused unconditional fallthrough, returning duplicate values
* fix: fs.sh — `has_files()` refactored to return early on first match via `return 0` instead of using a flag variable
* fix: logging.sh — log rotation simplified; `MALFORMED` manifest detection now explicitly logged to run log

### Changes
* chore: fs.sh — introduce `list_files_cached()` helper to centralize `find` invocation for future memoization
* chore: orchestrator.sh — call `build_exclusions` early to prevent unset-variable errors when helpers run before the standard build step

## v3.5.9 - 2025-11-18

### Changes
* change: default `BATCH_RULES` tuned from `0-2M:20,2M-50M:10,>50M:1` to `0-1M:20,1M-80M:5,>80M:1` — wider medium bucket and lower batch count for better throughput on mixed workloads

## v3.5.8 - 2025-11-16

### Changes
* chore: orchestrator.sh — log explicit `NO_REUSE=1` notice at run start when reuse heuristics are disabled, so operators see it in the run log

## v3.5.7 - 2025-11-16

### Fixes
* fix: process.sh — `--no-reuse` / `-R` now also disables the fallback path-based reuse check (mtime+size match); previously only the inode-based reuse was gated

## v3.5.6 - 2025-11-16

### Features
* feat: disable reuse heuristics (`-R` / `--no-reuse`) — new flag forces full rehash of all files, bypassing both inode-based and path-based incremental reuse; `NO_REUSE` global in `init.sh`; guards added around both reuse paths in `process.sh`

### Tests
* test: benchmark script updated to use `-R` flag and drop page cache between runs for accurate disk-bound timings

## v3.5.5 - 2025-11-16

### Tests
* test: new `tests/test_parallel.sh` — benchmark harness for parallel hashing; creates synthetic dataset (~2.3 GB across 5 file-size tiers), sweeps parallel jobs and batch rule combinations, records elapsed times to CSV

## v3.5.4 - 2025-11-15

### Changes
* chore: process.sh — add debug logging of effective `BATCH_RULES`, `PARALLEL_JOBS`, and `DRY_RUN` at start of `process_single_directory()`

## v3.5.3 - 2025-11-15

### Features
* feat: configurable batch rules (`-b RULES` / `--batch RULES`) — user-defined adaptive batching thresholds (e.g. `"0-2M:20,2M-50M:10,>50M:1"`); `BATCH_RULES` global with format validation in `parse_args()`; `classify_batch_size()` now parses the rules string with `numfmt --from=iec` unit conversion; added to `--help` output

## v3.5.2 - 2025-11-15

### Features
* feat: adaptive batch hashing — new `_do_hash_batch` worker in `hash.sh` hashes multiple files per subprocess instead of one-file-per-fork; `classify_batch_size()` in `process.sh` selects batch size by file size (small <2MB: 20, medium <50MB: 10, large: 1); last partial batch flushed before wait

## v3.5.1 - 2025-11-15

### Fixes
* fix: process.sh — switch parallel hash results from single shared file to per-worker output files (`results_dir/` with `*.out` per worker) to eliminate write interleaving when multiple workers append concurrently

## v3.4.9 - 2025-11-15

### Changes
* chore: demote per-file reuse/hash log messages from `log` to `vlog` — "Reusing hash via inode", "Reusing hash for unchanged file", and "Hashed ..." are now verbose-only, reducing console noise at default verbosity
* chore: elevate `verify_md5_file` startup message from `dbg` to `vlog` for better operator visibility
* chore: `-vv` (double verbose) now unlocks debug-level logging (`log_level=3`) without requiring `-d`

## v3.4.8 - 2025-11-15

### Features
* feat: per-directory MD5-details verification during planning — `emit_md5_file_details()` in logging.sh parses `.md5` manifests (GNU and BSD format) and writes per-file `MISSING:` / `MISMATCH:` / `VERIFIED:` lines to the run log; `emit_md5_detail()` emits compact summary to console; planner invokes details for all three scheduling paths
* feat: `--md5-details` / `--no-md5-details` / `-z` CLI flags — toggle per-directory MD5 verification during planning; `VERIFY_MD5_DETAILS` global (default 1)

### Changes
* chore: hash.sh — rename parallel job arrays `pids`/`pids_count` to `HASH_PIDS`/`HASH_PIDS_COUNT` to avoid collisions with other parallel subsystems
* chore: compat.sh — `map_set`/`map_get`/`map_del` now use `with_lock()` when `flock` is available to prevent lost updates under concurrent access
* chore: process.sh — replace RETURN trap with explicit `_proc_cleanup()` call at function exit for deterministic temp file cleanup
* chore: meta.sh — `with_lock()` no longer removes the lockfile after releasing, avoiding races with concurrent openers
* chore: logging.sh — log rotation pruning uses `base_noext.*.log` pattern and fixes off-by-one in rotated file pruning

## v3.4.7 - 2025-11-15

### Features
* feat: `--md5-details` / `--no-md5-details` / `-z` CLI flags — enable or disable per-directory MD5 verification in the planner; `VERIFY_MD5_DETAILS` global default 1; usage text updated
* feat: planner emits verbose `PLAN: skip/process $d reason=...` diagnostic lines with structured reason tags (hidden, root-protected, verify-only, first-run-md5-only, no-user-files, newer-file-detected, filecount-mismatch, meta-verified, meta-missing, meta-invalid, no-sumfile)

### Fixes
* fix: planner.sh — guard `verify_meta_sig` call with `[ -f "$metaf" ]` to avoid errors when meta file does not exist
* fix: process.sh — remove early `DRY RUN:` guard that prevented temp file creation, fixing downstream writes that rely on `tmp_sum`/`tmp_meta` being initialized

## v3.4.6 - 2025-11-15

### Fixes
* fix: `has_files()` / `has_local_files()` — rotated log exclusion now matches `ALT_LOG_EXCL.*.log` pattern instead of `LOG_BASE.*.log`, preventing user files with similar names from being incorrectly excluded
* fix: `build_exclusions()` — `ALT_LOG_EXCL` now strips `.log` suffix so rotated file patterns match correctly
* fix: logging.sh `rotate_log()` — strip trailing `.log` from base name before appending timestamp, producing `base.TIMESTAMP.log` instead of `base.log.TIMESTAMP.log`
* fix: meta.sh `with_lock()` — add fallback warning via `record_error` when fd 9 open fails; close fd via `eval` for shell portability
* fix: logging.sh `record_error()` — add defensive `declare -ga errors` to ensure array exists even if init.sh was not sourced

## v3.4.5 - 2025-11-15

### Features
* feat: `has_local_files()` helper in fs.sh — returns 0 if a directory has any non-tool regular file directly inside it (maxdepth 1); mirrors `has_files()` exclusion logic
* feat: Makefile — add `user-reinstall` target (uninstall + install)

### Changes
* chore: first_run.sh — simplify scheduling logic to a single definitive rule: schedule only if `has_files()`, otherwise skip with clear log message
* chore: planner.sh — quick preview now uses `has_files()` + `has_local_files()` dual check; SKIP_EMPTY check consolidated to top-level `has_files()` guard
* chore: process.sh — SKIP_EMPTY guard now uses `has_local_files()` instead of `has_files()` (skip only if no files directly in directory)
* chore: fs.sh — remove stale `lib/checksums.sh` entrypoint

## v3.4.4 - 2025-11-15

### Fixes
* fix: first_run.sh — pass directory as first argument to `dir_log_append()` calls (was passing log message as directory)
* fix: `has_files()` — replace subshell pipe loop with process substitution so early-exit propagates correctly
* fix: hash.sh `_par_wait_all()` — guard empty pids array and null entries before `wait` to prevent unbound variable errors under `set -u`
* fix: loader.sh — skip `checksums.sh` during dynamic lib sourcing to prevent re-entry when entrypoint lives in `lib/`
* fix: planner.sh — use POSIX-safe `sh -c` instead of `bash -c` in `-newer` xargs check; add `-r` flag to xargs

## v3.4.3 - 2025-11-15

### Features
* feat: add `lib/checksums.sh` — standalone entrypoint that sources init.sh + loader.sh and calls `main()`, preserving original CLI behavior; includes candidate search paths for system installs

### Changes
* chore: first_run.sh — SKIP_EMPTY now distinguishes `.md5`-only directories (still schedule overwrite) from truly empty directories (skip scheduling)
* chore: orchestrator.sh — first-run overwrite lookup rebuilt with `declare -gA` / `unset` cycle for clean state; null-guard `$d` before map operations
* chore: planner.sh — first-run carve-out in full planner requires `has_local_files()` in addition to missing `.meta`/`.log`

## v3.4.2 - 2025-11-14

### Changes
* chore: first_run.sh — SKIP_EMPTY now respected in all scheduling paths (verified-OK, overwrite, and interactive prompt); prevents scheduling empty/container-only directories for processing

## v3.4.1 - 2025-11-14

### Fixes
* fix: init.sh — restore proper quoting in `determine_VER()` whitespace-trim expression (broken in v3.3.9)
* fix: orchestrator.sh — move `build_exclusions()` call after config/CLI parsing so exclusion patterns reflect runtime settings
* fix: planner.sh — quick preview SKIP_EMPTY uses `find -maxdepth 1` shallow test for faster preview; full planner uses POSIX-safe `-newer` check via `sh -c` with positional args

## v3.3.9 - 2025-11-14

### Features
* feat: `has_files()` in fs.sh now excludes tool-generated artifacts (`.md5`, `.meta`, `.log`, rotated logs, run logs, lock files, `EXCLUDE_PATTERNS`) so directories containing only sidecar files are correctly treated as empty

### Changes
* chore: process.sh — first-run overwrite lookup allows SKIP_EMPTY to be bypassed for explicitly scheduled directories
* chore: orchestrator.sh — build lookup from `first_run_overwrite` array; clean up entries after processing
* chore: init.sh — declare `first_run_overwrite_set` associative array and `first_run_overwrite` indexed array at init time

## v3.3.8 - 2025-11-14

### Features
* feat: `has_files()` helper in fs.sh — fast recursive check for any regular file under a directory; replaces inline `find -type f -print -quit | grep -q .` pattern across codebase

### Changes
* chore: logging.sh — `rotate_log()` now checks for `#run` header before rotating (avoids creating rotated file on first write); rotated files use `.log` suffix
* chore: replace inline `find -type f` empty-directory checks in orchestrator.sh, planner.sh, process.sh, and logging.sh with `has_files()` calls
* chore: process.sh — root guard now compares canonical paths via `cd && pwd -P` to handle trailing slashes and symlinks

## v3.3.7 - 2025-11-14

### Changes
* chore: process.sh — ensure associative `meta_inode_dev`/`meta_size`/`meta_hash_by_path` arrays are declared at module load time to prevent unbound variable errors when process.sh is sourced before init.sh meta declarations

## v3.3.5 - 2025-11-14

Release automation; no user-facing changes.

## v3.3.4 - 2025-11-14

Release automation; no user-facing changes.

## v3.3.2 - 2025-11-14

Release automation; no user-facing changes.

## v3.3.1 - 2025-11-14

### Features
* feat: separate first-run log file (`.first-run.log`) instead of sharing run log; first-run targets now selected when either `.meta` OR `.log` is missing (was: both missing); deduplication via `_fr_seen` associative array; MISMATCH log format changed to tab-delimited with full file paths

### Changes
* chore: fs.sh — `build_exclusions()` adds `RUN_EXCL` and `FIRST_RUN_EXCL` basenames; `find_file_expr` excludes first-run log; `EXCLUDE_PATTERNS` array populated with all tool-generated basenames
* chore: orchestrator.sh — expanded header comments documenting responsibilities and rationale; `processed_dirs` tracking to prevent skip-log clobbering of already-processed directories; `_in_array()` helper
* chore: first_run.sh — log messages route through `dir_log_append` instead of `log` for per-directory log files

## v3.2.7 - 2025-11-13

Release automation; no user-facing changes.

## v3.2.6 - 2025-11-13

Release automation; no user-facing changes.

## v3.2.5 - 2025-11-13

### Changes
* chore: Makefile — normalize `help` target alignment (replace mixed tabs with consistent spacing)

## v3.2.4 - 2025-10-20

Release automation; no user-facing changes.

## v3.2.3 - 2025-10-20

Release automation; no user-facing changes.

## v3.2.2 - 2025-10-19

Release automation; no user-facing changes.

## v3.2.1 - 2025-10-19

Release automation; no user-facing changes.

## v3.2.0 - 2025-10-19

### Changes
* chore: args.sh — rewrite with structured header comments documenting purpose, design notes, expected globals, and example usage; guard missing positional `DIRECTORY` under `set -u` with explicit `$#` check
* chore: init.sh — rewrite header comments to document responsibilities, key features, and configuration

## v3.1.2 - 2025-10-19

### Features
* feat: `--skip-empty` and `--allow-root-sidefiles` CLI flags — expose `SKIP_EMPTY` and `NO_ROOT_SIDEFILES` controls introduced in v3.0.0 as command-line options; usage text updated with examples

### Changes
* chore: logging.sh — `dir_log_append()` and `dir_log_skip()` honor `NO_ROOT_SIDEFILES` and `SKIP_EMPTY` guards
* chore: planner.sh — both quick and full planners skip root directory when `NO_ROOT_SIDEFILES=1` and skip empty directories when `SKIP_EMPTY=1`
* chore: process.sh — `process_single_directory()` has root guard and SKIP_EMPTY early-return before any side effects; `decide_directories_plan()` moved to planner.sh
* chore: init.sh — set `MD5_FILENAME`/`META_FILENAME`/`LOG_FILENAME` eagerly at declaration; use `declare -g`/`declare -ga`/`declare -gA` for globals

## v3.0.0 - 2025-10-19

### Features
* feat: modular architecture — monolithic `checksums.sh` v2.12.5 split into `lib/` modules (`init.sh`, `loader.sh`, `planner.sh`, `orchestrator.sh`, `process.sh`, `hash.sh`, `logging.sh`, `meta.sh`, `stat.sh`, `fs.sh`, `args.sh`, `usage.sh`, `tools.sh`, `compat.sh`)
* feat: `SKIP_EMPTY` (default 1) — skip creating .meta/.log/.md5 for empty or container-only directories; early-return in `process_single_directory` before any side effects
* feat: `NO_ROOT_SIDEFILES` (default 1) — block sidecar file creation in root TARGET_DIR

## v2.12.5 - 2025-10-19

### Fixes
* fix: release.sh — replace first-match-only `sed -E "0,/^# Version:/s//"` with global `sed` substitution for portable version-line replacement (the `0,` address is a GNU sed extension)

## v2.12.4 - 2025-10-19

### Fixes
* fix: release.sh — replace fragile awk-based version-line injection with simple `sed` in-place substitution (fixes double-version bug from prior awk logic); add structured header comment documenting the release flow

## v2.12.3 - 2025-10-19

Release automation; no user-facing changes.

## v2.12.2 - 2025-10-19

### Fixes
* fix: checksums.sh — replace scalar fallback assignments with proper `declare -gA ...=()` empty-array initialization to prevent SC2178 array-to-string conversion; use `declare -p -A` capability check instead of no-op subshell test

## v2.12.1 - 2025-10-19

### Fixes
* fix: checksums.sh — declare global associative `meta_*` arrays with `declare -gA` when supported, preventing unbound-variable errors on first reference
* fix: checksums.sh — guard `${#meta_mtime[@]}` loops to skip iteration when arrays are empty (avoids "bad array subscript" on Bash 4.x)
* fix: checksums.sh — add `${..:-}` default-value guards on all associative array lookups to prevent unbound-variable errors under `set -u`
* fix: logging.sh — replace `ls -1t` log-rotation fallback with `find` + `stat` pipe for safe filename handling

## v2.12.0 - 2025-10-19

### Features
* feat: two-phase planning — `decide_quick_plan()` fast directory preview (no disk I/O) shown before user confirmation; `decide_directories_plan()` accurate stat-based planning moved to side-effect-free temp files (NUL-delimited)
* feat: orchestrator in checksums.sh — top-level `run_checksums()` with quick preview, user confirmation prompt (`-y` to skip), accurate planning, per-directory processing loop, first-run overwrite scheduling, cleanup, and summary
* feat: first_run.sh — non-destructive first-run verification; schedules overwrites in `first_run_overwrite` array for later execution by orchestrator

### Changes
* refactor: process.sh — extract `decide_directories_plan()` as standalone side-effect-free function; write manifest filenames with leading `./` to match standard `md5sum` output format
* refactor: meta.sh — canonical signature computation covering only stable data lines; `LC_ALL=C` locale pinning for deterministic hashes; fix awk `\b` misuse (backspace, not word boundary)
* refactor: logging.sh — unified verbosity via `log_level` (0-3); add `dir_log_append()`, `dir_log_skip()` helpers; harden `rotate_log()` with basename-only matching
* refactor: fs.sh — harden `build_exclusions()` to strip directory components; exclude rotated logs and run logs

## v2.5.25 - 2025-10-19

### Fixes
* fix: fs.sh — replace broken `${INCLUDE_PATTERNS[@]:=}` / `${EXCLUDE_PATTERNS[@]:=}` default-value syntax with proper `declare -a PATTERNS=()` initialization (fixes array-to-string coercion on startup)

## v2.5.24 - 2025-10-19

### Changes
* feat: multi-path library loader — checksums.sh searches `$BASE_DIR/lib`, `/usr/local/share/checksums/lib`, `/usr/share/checksums/lib` and exits 2 if none found
* fix: Makefile — split `LIBDIR` into `SHAREDIR` and `LIBDIR` (lib subdirectory); rename `uninstall-user` target to `user-uninstall`
* fix: install.sh — install libs to `SHAREDIR/lib/` subdirectory; add write-permission preflight check for `PREFIX`

## v2.5.23 - 2025-10-19

### Changes
* chore: release.sh — move dist tarball build before commit so artifacts are included in release; renumber steps

## v2.5.22 - 2025-10-19

### Changes
* chore: add `#` comment-block separators to lib file headers for consistent formatting
* chore: overhaul release.sh — rewrite version-line injection with awk, replace sed-based CHANGELOG promotion, add detached-HEAD branch handling, switch from `gh release create` to GitHub REST API with artifact upload

## v2.5.21 - 2025-10-19

Release automation; no user-facing changes.

## v2.5.20 - 2025-10-19

Release automation; no user-facing changes.

## v2.5.19 - 2025-10-19

Release automation; no user-facing changes.

## v2.5.18 - 2025-10-19

Release automation; no user-facing changes.

## v2.5.17 - 2025-10-19

Release automation; no user-facing changes.

## v2.5.16 - 2025-10-19

Release automation; no user-facing changes.

## v2.5.15 - 2025-10-19

Release automation; no user-facing changes.

## v2.5.14 - 2025-10-19

Release automation; no user-facing changes.

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
