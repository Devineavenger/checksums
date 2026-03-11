#!/usr/bin/env bats
# tests/test_check_mode.bats
#
# Tests for --check / -c external manifest verification (sha256sum -c interop).
#
# Verifies:
#  - Basic OK/FAILED/FAILED-open-or-read output for GNU and BSD manifest formats
#  - Algorithm auto-detection from manifest file extension
#  - Algorithm override via -a flag
#  - Quiet mode (-q) suppresses OK lines
#  - Parallel mode (-p N) produces correct results
#  - Default base directory (CWD) when DIRECTORY argument omitted
#  - Summary warnings on stderr
#  - Empty manifest, comments, blank lines handling
#  - Conflict detection with incompatible flags

load test_helper/bats-support/load
load test_helper/bats-assert/load

setup() {
  CHECKSUMS="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/checksums.sh"
  chmod +x "$CHECKSUMS" 2>/dev/null || true
  TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chk_test.XXXXXX")"

  # Create test files
  echo "hello" > "$TEST_DIR/file1.txt"
  echo "world" > "$TEST_DIR/file2.txt"
  mkdir -p "$TEST_DIR/subdir"
  echo "nested" > "$TEST_DIR/subdir/file3.txt"
}

teardown() {
  [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR" 2>/dev/null || true
}

# Helper: generate GNU-format manifest using md5sum
_make_md5_manifest() {
  local dir="$1" out="$2"
  (cd "$dir" && md5sum file1.txt file2.txt) > "$out"
}

# Helper: generate GNU-format manifest using sha256sum
_make_sha256_manifest() {
  local dir="$1" out="$2"
  (cd "$dir" && sha256sum file1.txt file2.txt) > "$out"
}

# ----------------------------------------------------------------
# Basic functionality
# ----------------------------------------------------------------

@test "-c: all files OK (GNU md5 format)" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_success
  assert_output --partial "file1.txt: OK"
  assert_output --partial "file2.txt: OK"
}

@test "-c: hash mismatch detected" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  # Corrupt file1.txt after manifest was created
  echo "corrupted" > "$TEST_DIR/file1.txt"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_failure
  assert_output --partial "file1.txt: FAILED"
  assert_output --partial "file2.txt: OK"
}

@test "-c: missing file produces FAILED open or read" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  rm "$TEST_DIR/file1.txt"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_failure
  assert_output --partial "file1.txt: FAILED open or read"
  assert_output --partial "file2.txt: OK"
}

@test "-c: unreadable file produces FAILED open or read" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  if [ "$(id -u)" -eq 0 ]; then
    # Root bypasses file permission bits; replacing the file with a directory
    # causes hash tools to fail with "Is a directory" even for root
    rm "$TEST_DIR/file1.txt"
    mkdir "$TEST_DIR/file1.txt"
  else
    chmod 000 "$TEST_DIR/file1.txt"
  fi
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_failure
  assert_output --partial "file1.txt: FAILED open or read"
}

# ----------------------------------------------------------------
# Algorithm auto-detection
# ----------------------------------------------------------------

@test "-c: auto-detects sha256 from .sha256 extension" {
  _make_sha256_manifest "$TEST_DIR" "$TEST_DIR/manifest.sha256"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.sha256" "$TEST_DIR"
  assert_success
  assert_output --partial "file1.txt: OK"
  assert_output --partial "file2.txt: OK"
}

@test "-c: auto-detects md5 from .md5 extension" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_success
  assert_output --partial "file1.txt: OK"
}

@test "-c: -a overrides extension-based algorithm detection" {
  # Create sha256 manifest but name it .md5 (extension would suggest md5)
  _make_sha256_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  # Without -a override, auto-detection uses md5 (wrong) -> hashes won't match
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_failure
  # With -a sha256 override, correct algo is used -> hashes match
  run bash "$CHECKSUMS" -a sha256 -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_success
  assert_output --partial "file1.txt: OK"
}

# ----------------------------------------------------------------
# BSD format
# ----------------------------------------------------------------

@test "-c: BSD format manifest (MD5 (file) = hash)" {
  local h1 h2
  h1=$(md5sum "$TEST_DIR/file1.txt" | awk '{print $1}')
  h2=$(md5sum "$TEST_DIR/file2.txt" | awk '{print $1}')
  cat > "$TEST_DIR/manifest.md5" <<EOF
MD5 (file1.txt) = $h1
MD5 (file2.txt) = $h2
EOF
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_success
  assert_output --partial "file1.txt: OK"
  assert_output --partial "file2.txt: OK"
}

# ----------------------------------------------------------------
# Output control
# ----------------------------------------------------------------

@test "-c -q: quiet mode suppresses OK lines" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" -q "$TEST_DIR"
  assert_success
  refute_output --partial ": OK"
}

@test "-c -q: quiet mode still shows FAILED lines" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  echo "corrupted" > "$TEST_DIR/file1.txt"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" -q "$TEST_DIR"
  assert_failure
  assert_output --partial "file1.txt: FAILED"
  refute_output --partial ": OK"
}

# ----------------------------------------------------------------
# Summary warnings
# ----------------------------------------------------------------

@test "-c: summary warning on stderr for mismatches" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  echo "corrupted" > "$TEST_DIR/file1.txt"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_failure
  # bats captures both stdout and stderr in $output
  assert_output --partial "WARNING: 1 computed checksum(s) did NOT match"
}

@test "-c: summary warning on stderr for read errors" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  rm "$TEST_DIR/file1.txt"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_failure
  assert_output --partial "WARNING: 1 listed file(s) could not be read"
}

# ----------------------------------------------------------------
# Path resolution
# ----------------------------------------------------------------

@test "-c: relative paths resolved against explicit base directory" {
  (cd "$TEST_DIR/subdir" && md5sum file3.txt) > "$TEST_DIR/manifest_sub.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest_sub.md5" "$TEST_DIR/subdir"
  assert_success
  assert_output --partial "file3.txt: OK"
}

@test "-c: default base directory is CWD when DIRECTORY omitted" {
  (cd "$TEST_DIR" && md5sum file1.txt file2.txt) > "$TEST_DIR/manifest.md5"
  # Run from TEST_DIR so CWD-based resolution works
  run bash -c "cd '$TEST_DIR' && bash '$CHECKSUMS' -c manifest.md5"
  assert_success
  assert_output --partial "file1.txt: OK"
}

@test "-c: manifest with ./ prefixed paths" {
  (cd "$TEST_DIR" && md5sum ./file1.txt ./file2.txt) > "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_success
  assert_output --partial "file1.txt: OK"
  assert_output --partial "file2.txt: OK"
}

# ----------------------------------------------------------------
# Edge cases
# ----------------------------------------------------------------

@test "-c: empty manifest exits 0" {
  touch "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_success
}

@test "-c: manifest with comments and blank lines" {
  local h1
  h1=$(md5sum "$TEST_DIR/file1.txt" | awk '{print $1}')
  cat > "$TEST_DIR/manifest.md5" <<EOF
# This is a comment

$h1  file1.txt

# Another comment
EOF
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_success
  assert_output --partial "file1.txt: OK"
}

# ----------------------------------------------------------------
# Parallel mode
# ----------------------------------------------------------------

@test "-c -p 2: parallel verification produces correct results" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" -p 2 "$TEST_DIR"
  assert_success
  assert_output --partial "file1.txt: OK"
  assert_output --partial "file2.txt: OK"
}

@test "-c -p 2: parallel detects mismatch" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  echo "corrupted" > "$TEST_DIR/file2.txt"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" -p 2 "$TEST_DIR"
  assert_failure
  assert_output --partial "file1.txt: OK"
  assert_output --partial "file2.txt: FAILED"
}

# ----------------------------------------------------------------
# Conflict detection
# ----------------------------------------------------------------

@test "-c conflicts with --status" {
  touch "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" -S "$TEST_DIR"
  assert_failure
  assert_output --partial "--check is incompatible with --status"
}

@test "-c conflicts with --verify-only" {
  touch "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" -V "$TEST_DIR"
  assert_failure
  assert_output --partial "--check is incompatible with --verify-only"
}

@test "-c conflicts with --first-run" {
  touch "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" -F "$TEST_DIR"
  assert_failure
  assert_output --partial "--check is incompatible with --first-run"
}

@test "-c conflicts with --dry-run" {
  touch "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" -n "$TEST_DIR"
  assert_failure
  assert_output --partial "--check is incompatible with --dry-run"
}

@test "-c: nonexistent manifest file produces fatal error" {
  run bash "$CHECKSUMS" -c "$TEST_DIR/nonexistent.md5" "$TEST_DIR"
  assert_failure
  assert_output --partial "Manifest file not found"
}

# ----------------------------------------------------------------
# Short vs long flag parity
# ----------------------------------------------------------------

@test "-c and --check produce identical results" {
  _make_md5_manifest "$TEST_DIR" "$TEST_DIR/manifest.md5"
  run bash "$CHECKSUMS" -c "$TEST_DIR/manifest.md5" "$TEST_DIR"
  local short_output="$output"
  local short_status="$status"

  run bash "$CHECKSUMS" --check "$TEST_DIR/manifest.md5" "$TEST_DIR"
  assert_equal "$status" "$short_status"
  # Both should succeed and show OK lines
  assert_output --partial "file1.txt: OK"
  assert_output --partial "file2.txt: OK"
}
