#!/usr/bin/env bats
# tests/test_completions.bats
#
# Tests for shell completion files (bash and zsh).
#
# Verifies:
#  - Completion files exist in completions/
#  - Valid shell syntax (bash -n, zsh -n)
#  - Expected function names and registration directives
#  - All short and long flags are covered
#  - All enumerated values (algorithms, formats, choices) are present

load test_helper/bats-support/load
load test_helper/bats-assert/load

COMP_DIR="$BATS_TEST_DIRNAME/../completions"

# ----------------------------------------------------------------
# File existence
# ----------------------------------------------------------------

@test "bash completion file exists" {
  [ -f "$COMP_DIR/checksums.bash" ]
}

@test "zsh completion file exists" {
  [ -f "$COMP_DIR/_checksums" ]
}

# ----------------------------------------------------------------
# Syntax validity
# ----------------------------------------------------------------

@test "bash completion file has valid syntax" {
  run bash -n "$COMP_DIR/checksums.bash"
  assert_success
}

@test "zsh completion file has valid syntax" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
  run zsh -n "$COMP_DIR/_checksums"
  assert_success
}

# ----------------------------------------------------------------
# Function names and registration
# ----------------------------------------------------------------

@test "bash completion defines _checksums function" {
  run grep -q '_checksums()' "$COMP_DIR/checksums.bash"
  assert_success
}

@test "bash completion registers with complete command" {
  run grep -qE 'complete .* checksums$' "$COMP_DIR/checksums.bash"
  assert_success
}

@test "zsh completion has compdef directive" {
  run grep -q '#compdef checksums' "$COMP_DIR/_checksums"
  assert_success
}

# ----------------------------------------------------------------
# Short flag coverage
# ----------------------------------------------------------------

@test "bash completion covers all short flags" {
  local missing=()
  for flag in -h -n -d -v -r -R -F -K -z -y -V -S -Q -M -q -L -a -m -o -C -p -P -b -f -l -c -D -e -i; do
    grep -qw -- "$flag" "$COMP_DIR/checksums.bash" || missing+=("$flag")
  done
  [ ${#missing[@]} -eq 0 ] || fail "Missing short flags in bash completion: ${missing[*]}"
}

@test "zsh completion covers all short flags" {
  local missing=()
  for flag in -h -n -d -v -r -R -F -K -z -y -V -S -Q -M -q -L -a -m -o -C -p -P -b -f -l -c -D -e -i; do
    grep -qw -- "$flag" "$COMP_DIR/_checksums" || missing+=("$flag")
  done
  [ ${#missing[@]} -eq 0 ] || fail "Missing short flags in zsh completion: ${missing[*]}"
}

# ----------------------------------------------------------------
# Long flag coverage
# ----------------------------------------------------------------

@test "bash completion covers all long flags" {
  local missing=()
  for flag in --help --version --config --base-name --log-base --store-dir \
      --per-file-algo --meta-sig --no-reuse --parallel --parallel-dirs --batch \
      --dry-run --debug --verbose --force-rebuild --assume-yes --assume-no \
      --quiet --no-progress --minimal --first-run --first-run-choice --first-run-keep \
      --verify-only --check --no-md5-details --md5-details --status \
      --skip-empty --no-skip-empty --allow-root-sidefiles \
      --follow-symlinks --no-follow-symlinks --exclude --include \
      --max-size --min-size --output; do
    grep -qF -- "$flag" "$COMP_DIR/checksums.bash" || missing+=("$flag")
  done
  [ ${#missing[@]} -eq 0 ] || fail "Missing long flags in bash completion: ${missing[*]}"
}

@test "zsh completion covers all long flags" {
  local missing=()
  for flag in --help --version --config --base-name --log-base --store-dir \
      --per-file-algo --meta-sig --no-reuse --parallel --parallel-dirs --batch \
      --dry-run --debug --verbose --force-rebuild --assume-yes --assume-no \
      --quiet --no-progress --minimal --first-run --first-run-choice --first-run-keep \
      --verify-only --check --no-md5-details --md5-details --status \
      --skip-empty --no-skip-empty --allow-root-sidefiles \
      --follow-symlinks --no-follow-symlinks --exclude --include \
      --max-size --min-size --output; do
    grep -qF -- "$flag" "$COMP_DIR/_checksums" || missing+=("$flag")
  done
  [ ${#missing[@]} -eq 0 ] || fail "Missing long flags in zsh completion: ${missing[*]}"
}

# ----------------------------------------------------------------
# Enumerated value coverage
# ----------------------------------------------------------------

@test "bash completion includes all algorithm names" {
  local missing=()
  for algo in md5 sha1 sha224 sha256 sha384 sha512; do
    grep -qw "$algo" "$COMP_DIR/checksums.bash" || missing+=("$algo")
  done
  [ ${#missing[@]} -eq 0 ] || fail "Missing algorithms in bash completion: ${missing[*]}"
}

@test "zsh completion includes all algorithm names" {
  local missing=()
  for algo in md5 sha1 sha224 sha256 sha384 sha512; do
    grep -qw "$algo" "$COMP_DIR/_checksums" || missing+=("$algo")
  done
  [ ${#missing[@]} -eq 0 ] || fail "Missing algorithms in zsh completion: ${missing[*]}"
}

@test "bash completion includes all log formats" {
  local missing=()
  for fmt in text json csv; do
    grep -qw "$fmt" "$COMP_DIR/checksums.bash" || missing+=("$fmt")
  done
  [ ${#missing[@]} -eq 0 ] || fail "Missing log formats in bash completion: ${missing[*]}"
}

@test "bash completion includes all first-run choices" {
  local missing=()
  for choice in skip overwrite prompt; do
    grep -qw "$choice" "$COMP_DIR/checksums.bash" || missing+=("$choice")
  done
  [ ${#missing[@]} -eq 0 ] || fail "Missing first-run choices in bash completion: ${missing[*]}"
}

@test "bash completion includes auto for parallel" {
  run grep -qw "auto" "$COMP_DIR/checksums.bash"
  assert_success
}
