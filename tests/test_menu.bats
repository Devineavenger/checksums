#!/usr/bin/env bats
# test_menu.bats — tests for the interactive menu mode (lib/menu.sh)

load test_helper/bats-support/load
load test_helper/bats-assert/load

# ---------------------------------------------------------------------------
# Helper: source the minimum lib stack needed by menu.sh
# ---------------------------------------------------------------------------
_source_menu_libs() {
  source "$BATS_TEST_DIRNAME/../lib/init.sh"
  source "$BATS_TEST_DIRNAME/../lib/color.sh"
  source "$BATS_TEST_DIRNAME/../lib/logging.sh"
  source "$BATS_TEST_DIRNAME/../lib/usage.sh"
  source "$BATS_TEST_DIRNAME/../lib/menu.sh"
}

# ---------------------------------------------------------------------------
# Sourcing sanity
# ---------------------------------------------------------------------------

@test "lib/menu.sh sources cleanly" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/menu.sh"
  ' 2>&1
  assert_success
  refute_output --partial "command not found"
  refute_output --partial "syntax error"
}

@test "run_menu function exists after sourcing" {
  _source_menu_libs
  [ "$(type -t run_menu)" = "function" ]
}

# ---------------------------------------------------------------------------
# TTY guard
# ---------------------------------------------------------------------------

@test "run_menu fatals when stdin is not a TTY" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/menu.sh"
    run_menu
  ' </dev/null 2>&1
  assert_failure
  assert_output --partial "interactive terminal"
}

@test "run_menu fatals when stdout is not a TTY" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/menu.sh"
    run_menu
  ' 2>&1
  # bats 'run' captures stdout so it won't be a TTY
  assert_failure
  assert_output --partial "interactive terminal"
}

# ---------------------------------------------------------------------------
# Validators
# ---------------------------------------------------------------------------

@test "_menu_validate_algo accepts md5" {
  _source_menu_libs
  run _menu_validate_algo "md5"
  assert_success
}

@test "_menu_validate_algo accepts sha256" {
  _source_menu_libs
  run _menu_validate_algo "sha256"
  assert_success
}

@test "_menu_validate_algo accepts comma-separated multi-algo" {
  _source_menu_libs
  run _menu_validate_algo "md5,sha256,sha512"
  assert_success
}

@test "_menu_validate_algo rejects invalid algorithm" {
  _source_menu_libs
  run _menu_validate_algo "crc32"
  assert_failure
  assert_output --partial "Invalid algorithm"
}

@test "_menu_validate_algo rejects mixed valid/invalid" {
  _source_menu_libs
  run _menu_validate_algo "md5,bogus"
  assert_failure
  assert_output --partial "Invalid algorithm"
}

@test "_menu_validate_meta_sig accepts sha256" {
  _source_menu_libs
  run _menu_validate_meta_sig "sha256"
  assert_success
}

@test "_menu_validate_meta_sig accepts none" {
  _source_menu_libs
  run _menu_validate_meta_sig "none"
  assert_success
}

@test "_menu_validate_meta_sig rejects invalid" {
  _source_menu_libs
  run _menu_validate_meta_sig "blake2"
  assert_failure
  assert_output --partial "Invalid meta-sig"
}

@test "_menu_validate_dir rejects non-existent path" {
  _source_menu_libs
  run _menu_validate_dir "/no/such/dir/$$"
  assert_failure
  assert_output --partial "Directory not found"
}

@test "_menu_validate_dir accepts existing directory" {
  _source_menu_libs
  run _menu_validate_dir "$BATS_TEST_DIRNAME"
  assert_success
}

@test "_menu_validate_file rejects non-existent file" {
  _source_menu_libs
  run _menu_validate_file "/no/such/file.$$"
  assert_failure
  assert_output --partial "File not found"
}

@test "_menu_validate_file accepts existing file" {
  _source_menu_libs
  run _menu_validate_file "$BATS_TEST_DIRNAME/../checksums.sh"
  assert_success
}

@test "_menu_validate_parallel accepts integer" {
  _source_menu_libs
  run _menu_validate_parallel "4"
  assert_success
}

@test "_menu_validate_parallel accepts auto" {
  _source_menu_libs
  run _menu_validate_parallel "auto"
  assert_success
}

@test "_menu_validate_parallel accepts fraction" {
  _source_menu_libs
  run _menu_validate_parallel "3/4"
  assert_success
}

@test "_menu_validate_parallel rejects garbage" {
  _source_menu_libs
  run _menu_validate_parallel "many"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "_menu_validate_size accepts 10M" {
  _source_menu_libs
  run _menu_validate_size "10M"
  assert_success
}

@test "_menu_validate_size accepts plain bytes" {
  _source_menu_libs
  run _menu_validate_size "1024"
  assert_success
}

@test "_menu_validate_size rejects invalid" {
  _source_menu_libs
  run _menu_validate_size "big"
  assert_failure
  assert_output --partial "Invalid size"
}

@test "_menu_validate_log_format accepts text" {
  _source_menu_libs
  run _menu_validate_log_format "text"
  assert_success
}

@test "_menu_validate_log_format rejects invalid" {
  _source_menu_libs
  run _menu_validate_log_format "xml"
  assert_failure
  assert_output --partial "Invalid format"
}

@test "_menu_validate_first_run_choice accepts skip" {
  _source_menu_libs
  run _menu_validate_first_run_choice "skip"
  assert_success
}

@test "_menu_validate_first_run_choice accepts overwrite" {
  _source_menu_libs
  run _menu_validate_first_run_choice "overwrite"
  assert_success
}

@test "_menu_validate_first_run_choice accepts prompt" {
  _source_menu_libs
  run _menu_validate_first_run_choice "prompt"
  assert_success
}

@test "_menu_validate_first_run_choice rejects invalid" {
  _source_menu_libs
  run _menu_validate_first_run_choice "delete"
  assert_failure
  assert_output --partial "Invalid choice"
}

# ---------------------------------------------------------------------------
# Command construction
# ---------------------------------------------------------------------------

# Helper: set up _m_* state variables for a default generate run,
# then call _menu_build_command and output the constructed command string.
_build_default_cmd() {
  _source_menu_libs
  _m_mode="generate"
  _m_target="."
  _m_check_file=""
  _m_algo="md5"
  _m_meta_sig="sha256"
  _m_exclude=""
  _m_include=""
  _m_max_size=""
  _m_min_size=""
  _m_follow_symlinks="n"
  _m_parallel="1"
  _m_parallel_dirs="1"
  _m_batch="0-10M:20,10M-40M:20,>40M:5"
  _m_base_name="#####checksums#####"
  _m_log_base=""
  _m_store_dir=""
  _m_minimal="n"
  _m_dry_run="n"
  _m_force_rebuild="n"
  _m_assume_yes="n"
  _m_log_format="text"
  _m_verbose="n"
  _m_quiet="n"
  _m_progress="y"
  _m_no_reuse="n"
  _m_debug="n"
  _m_md5_details="y"
  _m_skip_empty="y"
  _m_allow_root="n"
  _m_first_run="n"
  _m_first_run_choice=""
  _m_first_run_keep="n"
}

@test "_menu_build_command default generate produces minimal command" {
  _build_default_cmd
  _menu_build_command
  [ "$_menu_cmd_str" = "checksums ." ]
}

@test "_menu_build_command verify-only mode adds --verify-only" {
  _build_default_cmd
  _m_mode="verify"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"--verify-only"* ]]
}

@test "_menu_build_command status mode adds --status" {
  _build_default_cmd
  _m_mode="status"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"--status"* ]]
}

@test "_menu_build_command check mode adds --check FILE" {
  _build_default_cmd
  _m_mode="check"
  _m_check_file="/tmp/manifest.sha256"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"--check '/tmp/manifest.sha256'"* ]]
}

@test "_menu_build_command non-default algo includes -a" {
  _build_default_cmd
  _m_algo="sha256"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-a sha256"* ]]
}

@test "_menu_build_command default algo omits -a" {
  _build_default_cmd
  _m_algo="md5"
  _menu_build_command
  [[ "$_menu_cmd_str" != *"-a"* ]]
}

@test "_menu_build_command multi-algo includes -a" {
  _build_default_cmd
  _m_algo="md5,sha256"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-a md5,sha256"* ]]
}

@test "_menu_build_command exclude patterns included" {
  _build_default_cmd
  _m_exclude="*.tmp,*.bak"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"--exclude '*.tmp,*.bak'"* ]]
}

@test "_menu_build_command parallel jobs included when non-default" {
  _build_default_cmd
  _m_parallel="4"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-p 4"* ]]
}

@test "_menu_build_command parallel=1 omits -p" {
  _build_default_cmd
  _m_parallel="1"
  _menu_build_command
  [[ "$_menu_cmd_str" != *"-p "* ]]
}

@test "_menu_build_command all non-default options together" {
  _build_default_cmd
  _m_algo="sha256"
  _m_meta_sig="none"
  _m_exclude="*.tmp"
  _m_parallel="auto"
  _m_parallel_dirs="4"
  _m_store_dir="/tmp/store"
  _m_dry_run="y"
  _m_assume_yes="y"
  _m_verbose="y"
  _m_quiet="n"
  _m_first_run="y"
  _m_first_run_choice="overwrite"
  _m_first_run_keep="y"
  _m_target="/data/project"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-a sha256"* ]]
  [[ "$_menu_cmd_str" == *"-m none"* ]]
  [[ "$_menu_cmd_str" == *"--exclude '*.tmp'"* ]]
  [[ "$_menu_cmd_str" == *"-p auto"* ]]
  [[ "$_menu_cmd_str" == *"-P 4"* ]]
  [[ "$_menu_cmd_str" == *"-D '/tmp/store'"* ]]
  [[ "$_menu_cmd_str" == *"-n"* ]]
  [[ "$_menu_cmd_str" == *"-y"* ]]
  [[ "$_menu_cmd_str" == *"-v"* ]]
  [[ "$_menu_cmd_str" == *"-F"* ]]
  [[ "$_menu_cmd_str" == *"-C overwrite"* ]]
  [[ "$_menu_cmd_str" == *"-K"* ]]
  [[ "$_menu_cmd_str" == *"/data/project"* ]]
}

@test "_menu_build_command minimal mode adds -M" {
  _build_default_cmd
  _m_minimal="y"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-M"* ]]
}

@test "_menu_build_command no-progress adds -Q" {
  _build_default_cmd
  _m_progress="n"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-Q"* ]]
}

@test "_menu_build_command follow-symlinks adds -L" {
  _build_default_cmd
  _m_follow_symlinks="y"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-L"* ]]
}

@test "_menu_build_command max-size adds --max-size" {
  _build_default_cmd
  _m_max_size="10M"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"--max-size 10M"* ]]
}

@test "_menu_build_command min-size adds --min-size" {
  _build_default_cmd
  _m_min_size="1K"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"--min-size 1K"* ]]
}

@test "_menu_build_command include patterns included" {
  _build_default_cmd
  _m_include="*.txt,*.md"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"--include '*.txt,*.md'"* ]]
}

@test "_menu_build_command json log format adds -o" {
  _build_default_cmd
  _m_log_format="json"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-o json"* ]]
}

@test "_menu_build_command text log format omits -o" {
  _build_default_cmd
  _m_log_format="text"
  _menu_build_command
  [[ "$_menu_cmd_str" != *"-o "* ]]
}

@test "_menu_build_command non-default base name adds -f" {
  _build_default_cmd
  _m_base_name="myprefix"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-f 'myprefix'"* ]]
}

@test "_menu_build_command force-rebuild adds -r" {
  _build_default_cmd
  _m_force_rebuild="y"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-r"* ]]
}

@test "_menu_build_command target with spaces is quoted" {
  _build_default_cmd
  _m_target="/data/my project"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"'/data/my project'"* ]]
}

@test "_menu_build_command check mode omits algo flag" {
  _build_default_cmd
  _m_mode="check"
  _m_check_file="/tmp/sums.sha256"
  _m_algo="sha256"
  _menu_build_command
  # In check mode, algo is auto-detected; should not appear even if non-default
  [[ "$_menu_cmd_str" != *"-a "* ]]
}

@test "_menu_build_command no-reuse adds -R" {
  _build_default_cmd
  _m_no_reuse="y"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-R"* ]]
}

@test "_menu_build_command no-reuse default omits -R" {
  _build_default_cmd
  _m_no_reuse="n"
  _menu_build_command
  [[ "$_menu_cmd_str" != *"-R"* ]]
}

@test "_menu_build_command debug adds -d" {
  _build_default_cmd
  _m_debug="y"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-d"* ]]
}

@test "_menu_build_command debug default omits -d" {
  _build_default_cmd
  _m_debug="n"
  _menu_build_command
  [[ "$_menu_cmd_str" != *"-d"* ]]
}

@test "_menu_build_command md5-details disabled adds -z" {
  _build_default_cmd
  _m_md5_details="n"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"-z"* ]]
}

@test "_menu_build_command md5-details default omits -z" {
  _build_default_cmd
  _m_md5_details="y"
  _menu_build_command
  [[ "$_menu_cmd_str" != *"-z"* ]]
}

@test "_menu_build_command no-skip-empty adds --no-skip-empty" {
  _build_default_cmd
  _m_skip_empty="n"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"--no-skip-empty"* ]]
}

@test "_menu_build_command skip-empty default omits flag" {
  _build_default_cmd
  _m_skip_empty="y"
  _menu_build_command
  [[ "$_menu_cmd_str" != *"skip-empty"* ]]
}

@test "_menu_build_command allow-root-sidefiles adds flag" {
  _build_default_cmd
  _m_allow_root="y"
  _menu_build_command
  [[ "$_menu_cmd_str" == *"--allow-root-sidefiles"* ]]
}

@test "_menu_build_command allow-root default omits flag" {
  _build_default_cmd
  _m_allow_root="n"
  _menu_build_command
  [[ "$_menu_cmd_str" != *"--allow-root-sidefiles"* ]]
}

# ---------------------------------------------------------------------------
# Flag parsing integration
# ---------------------------------------------------------------------------

@test "--menu flag sets MENU_MODE=1" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/usage.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/compat.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/args.sh"
    parse_args --menu
    echo "MENU_MODE=$MENU_MODE"
  ' 2>&1
  assert_success
  assert_output --partial "MENU_MODE=1"
}

@test "--interactive flag sets MENU_MODE=1" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/usage.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/compat.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/args.sh"
    parse_args --interactive
    echo "MENU_MODE=$MENU_MODE"
  ' 2>&1
  assert_success
  assert_output --partial "MENU_MODE=1"
}

@test "--menu does not require TARGET_DIR positional argument" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/usage.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/compat.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/args.sh"
    parse_args --menu
    echo "OK"
  ' 2>&1
  assert_success
  assert_output --partial "OK"
}

@test "--menu with pre-set flags preserves globals" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/init.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/color.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/logging.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/usage.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/compat.sh"
    source "'"$BATS_TEST_DIRNAME"'/../lib/args.sh"
    parse_args --menu -a sha256 -p auto
    echo "ALGO=$PER_FILE_ALGO PARALLEL=$PARALLEL_JOBS MENU=$MENU_MODE"
  ' 2>&1
  assert_success
  assert_output --partial "ALGO=sha256"
  assert_output --partial "PARALLEL=auto"
  assert_output --partial "MENU=1"
}

# ---------------------------------------------------------------------------
# Help text
# ---------------------------------------------------------------------------

@test "--help mentions --menu flag" {
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" --help 2>&1
  assert_success
  assert_output --partial "--menu"
}

@test "--help mentions --interactive flag" {
  run bash "$BATS_TEST_DIRNAME/../checksums.sh" --help 2>&1
  assert_success
  assert_output --partial "--interactive"
}

# ---------------------------------------------------------------------------
# Full interactive flow (scripted stdin with _MENU_FORCE_TTY)
# ---------------------------------------------------------------------------

@test "menu prints command with scripted input (print & exit)" {
  local tmpdir
  tmpdir=$(mktemp -d)

  # Build a script that sources libs directly, sets _MENU_FORCE_TTY, feeds
  # scripted input via a here-doc, and runs the menu.
  # Input sequence (31 prompts):
  #   Screen 1: mode=1 (generate), target=tmpdir
  #   Screen 2: algo=Enter, meta-sig=Enter, exclude=Enter, include=Enter,
  #             max-size=Enter, min-size=Enter, symlinks=Enter(n)
  #   Screen 3: parallel=Enter, parallel-dirs=Enter, batch=Enter,
  #             base-name=Enter, log-base=Enter, store-dir=Enter,
  #             minimal=Enter(n), skip-empty=Enter(y), allow-root=Enter(n)
  #   Screen 4: dry-run=Enter(n), force-rebuild=Enter(n), no-reuse=Enter(n),
  #             assume-yes=Enter(y), log-format=Enter, verbose=Enter(n),
  #             debug=Enter(n), quiet=Enter(n), progress=Enter(y),
  #             md5-details=Enter(y), first-run=Enter(n)
  #   Screen 5: choice=2 (print & exit)
  run timeout 10 bash -c '
    export _MENU_FORCE_TTY=1
    export NO_COLOR=1
    printf "1\n'"$tmpdir"'\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n2\n" \
      | bash "'"$BATS_TEST_DIRNAME"'/../checksums.sh" --menu
  ' 2>&1

  assert_success
  # The final print should show the constructed command
  assert_output --partial "checksums"
  assert_output --partial "$tmpdir"
  rm -rf "$tmpdir"
}
