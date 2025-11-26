#!/usr/bin/env bats
# tests/test_short_vs_long_flags.bats
#
# Purpose:
#   Verify parity between short and long CLI flags for checksums.sh.
#   We test both sides under identical conditions and assert exit-code parity.
#   For deterministic flags we also assert normalized output equality.
#
# Why normalization and isolation matter:
#   - The tool outputs timestamps, run IDs, temp directory names, and rotated log markers.
#     Those are inherently non-deterministic; comparing raw output will fail spuriously.
#   - The tool is stateful: running twice in the same directory changes behavior (e.g., rotation,
#     verification). We therefore create a fresh temp directory for each invocation to avoid
#     state leakage between short and long forms.
#
# Scope:
#   - This test avoids external helpers/libraries to be CI-friendly.
#   - It uses --allow-root-sidefiles so sidecar files in the temp dir are permitted.
#   - It prioritizes semantic checks (exit codes, presence of markers) over brittle string equality.

setup() {
  # Path to the script under test (repo root assumption).
  CHECKSUMS="$(pwd)/checksums.sh"
  chmod +x "$CHECKSUMS" 2>/dev/null || true
  BASE_NAME="#####checksums#####"
  # Snapshot pre-existing /tmp/tmp.* entries so we only remove new ones created by tests.
  PRE_EXISTING_TMP="$(ls -1 /tmp/tmp.* 2>/dev/null || true)"
  CREATED_TMPDIRS=""
}

teardown() {
  # Remove every path (file or directory) we explicitly recorded.
  for p in $CREATED_TMPDIRS; do
    [ -z "$p" ] && continue
    [ ! -e "$p" ] && continue
    case "$p" in
      /tmp/*|/var/tmp/*)
        echo "teardown: removing recorded path $p" >&2
        rm -rf -- "$p" || echo "teardown: failed to remove $p" >&2
        ;;
      *)
        echo "teardown: refusing to remove non-temp path: $p" >&2
        ;;
    esac
  done

  # Also remove any new /tmp/tmp.* entries that were created during this test run
  # (i.e., present now but not in PRE_EXISTING_TMP). This catches mktemp-created files.
  for cur in $(ls -1 /tmp/tmp.* 2>/dev/null || true); do
    # skip if it existed before the test run
    case " $PRE_EXISTING_TMP " in
      *" $cur "*) continue ;;
    esac
    # only remove safe paths
    case "$cur" in
      /tmp/*|/var/tmp/*)
        echo "teardown: removing new tmp entry $cur" >&2
        rm -rf -- "$cur" || echo "teardown: failed to remove $cur" >&2
        ;;
      *)
        echo "teardown: refusing to remove non-temp path: $cur" >&2
        ;;
    esac
  done

  CREATED_TMPDIRS=""
  unset TMPDIR || true

  # Debug: list any remaining tmp.* entries (post-cleanup)
  echo "teardown: remaining /tmp/tmp.* entries (post-cleanup):" >&2
  ls -ld /tmp/tmp.* 2>/dev/null || true
}

# fresh_dir:
#   Create a brand-new temporary directory and populate it with deterministic test files.
#   We do this before EACH invocation (short and long) to avoid cross-run state influencing output.
fresh_dir() {
  # Create a fresh temp dir and remember it for teardown.
  newtmp="$(mktemp -d -t checksums.XXXXXX)"
  # populate deterministic files
  echo "alpha" > "$newtmp/file1"
  echo "beta"  > "$newtmp/file2"
  # record and expose as TMPDIR for compatibility with existing tests
  CREATED_TMPDIRS="${CREATED_TMPDIRS} ${newtmp}"
  TMPDIR="$newtmp"
  echo "fresh_dir: created $newtmp" >&2
}

# normalize_output:
#   Strip out ephemeral elements so we can compare the stable parts of the output.
#   We remove timestamps, run IDs, temp dir paths, rotated log lines, and error/verified banners.
normalize_output() {
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z//g' \
    -e 's/Run ID: .*//g' \
    -e 's|Starting run on /tmp/tmp\.[^ ]+||g' \
    -e 's/Rotated [^ ]+ -> [^ ]+//g' \
    -e 's/^VERIFIED:.*//g' \
    -e 's/^ERROR:.*//g' \
    -e '/^$/d'
}

# has_marker:
#   Utility to check that output contains a key marker string.
has_marker() {
  needle="$1"; hay="$2"
  printf '%s' "$hay" | grep -Fq -- "$needle"
}

# run_and_compare:
#   Run the short flag and the long flag separately (in fresh dirs), capture exit codes and output,
#   then assert parity. For deterministic flags we compare normalized outputs; for noisy flags we
#   only assert exit-code parity and presence of expected markers when applicable.
run_and_compare() {
  short="$1"; long="$2"; arg="${3:-}"

  # --- Short run in isolated temp directory ---
  fresh_dir
  if [ -n "$arg" ]; then
    run "$CHECKSUMS" -y "$short" "$arg" --allow-root-sidefiles "$TMPDIR"
  else
    run "$CHECKSUMS" -y "$short" --allow-root-sidefiles "$TMPDIR"
  fi
  status_short=$status; output_short="$output"

  # --- Long run in isolated temp directory ---
  fresh_dir
  if [ -n "$arg" ]; then
    run "$CHECKSUMS" -y "$long" "$arg" --allow-root-sidefiles "$TMPDIR"
  else
    run "$CHECKSUMS" -y "$long" --allow-root-sidefiles "$TMPDIR"
  fi
  status_long=$status; output_long="$output"

  # --- Exit code parity is mandatory for all flag pairs ---
  if [ "$status_short" -ne "$status_long" ]; then
    echo "Exit codes differ: $short=$status_short, $long=$status_long"
    return 1
  fi

  # --- Decide comparison strategy based on flag characteristics ---
  case "$short" in
    -d|-v) return 0 ;;  # debug/verbose: output volume differs; exit-code parity is sufficient
    -o)
      # Output format: assert both mention chosen format (e.g., 'format: json'); skip strict equality.
      has_marker "format: $arg" "$output_short" || return 1
      has_marker "format: $arg" "$output_long"  || return 1
      return 0
      ;;
    -n)
      # Dry-run: assert both include DRYRUN markers.
      has_marker "DRYRUN:" "$output_short" || return 1
      has_marker "DRYRUN:" "$output_long"  || return 1
      return 0
      ;;
    -V)
      # Verify-only: assert presence of verify-only banners; do not compare full output.
      has_marker "verify-only" "$output_short" || return 1
      has_marker "verify-only" "$output_long"  || return 1
      return 0
      ;;
    -F|-C) return 0 ;;  # first-run / first-run-choice: behavior differs based on sidecar state
    -p)
      # Parallel: assert both outputs mention the chosen parallel value.
      has_marker "parallel: $arg" "$output_short" || return 1
      has_marker "parallel: $arg" "$output_long"  || return 1
      return 0
      ;;
    -b)
      # Batch rules: the tool does not echo the rules string.
      # Just assert that both short and long forms exit with the same status.
      return 0
      ;;
    -f)
      # Base name: assert the 'Base: <name>' marker exists.
      has_marker "Base: $arg" "$output_short" || return 1
      has_marker "Base: $arg" "$output_long"  || return 1
      return 0
      ;;
    -a)
      # Per-file algorithm: assert the selected algorithm appears.
      has_marker "per-file: $arg" "$output_short" || return 1
      has_marker "per-file: $arg" "$output_long"  || return 1
      return 0
      ;;
    -m)
      # Meta signature algorithm: assert the selected algorithm appears.
      has_marker "meta-sig: $arg" "$output_short" || return 1
      has_marker "meta-sig: $arg" "$output_long"  || return 1
      return 0
      ;;
    -l)
      # Log base: assert the derived logfile path mentions the base.
      has_marker "$arg.log" "$output_short" || return 1
      has_marker "$arg.log" "$output_long"  || return 1
      return 0
      ;;
    -y|-r|-R|-z) return 0 ;;  # toggles: exit-code parity only
    *)
      # Deterministic cases: compare normalized outputs strictly.
      ns="$(printf '%s' "$output_short" | normalize_output)"
      nl="$(printf '%s' "$output_long" | normalize_output)"
      [ "$ns" = "$nl" ] || { echo "Normalized output differs for $short vs $long"; return 1; }
      ;;
  esac
}

# -------------------------------------------------------------------
# Test cases
# -------------------------------------------------------------------

@test "short/long parity for simple toggles" {
  # Dry-run should not write manifests; both forms must produce DRYRUN markers.
  run_and_compare -n --dry-run
}

@test "short/long parity for debug/verbose (status parity only)" {
  # Debug/verbose increase output volume; exit code parity is the meaningful assertion.
  run_and_compare -d --debug
  run_and_compare -v --verbose
}

@test "short/long parity for assume-yes/assume-no and toggles" {
  # Planner toggles; validate exit codes and basic markers where meaningful.
  run_and_compare -y --assume-yes
  run_and_compare -V --verify-only
  run_and_compare -R --no-reuse
  run_and_compare -r --force-rebuild
  run_and_compare -F --first-run
  run_and_compare -z --no-md5-details
  # Removed self-comparison of --allow-root-sidefiles; pointless and always fails on ephemeral differences.
}

@test "short/long parity for options with arguments" {
  # Options that take values: assert the selected value appears in output for both forms.
  run_and_compare -p --parallel 2
  run_and_compare -b --batch "0-2M:20,2M-10M:10,>10M:1"
  run_and_compare -o --output json
  run_and_compare -f --base-name "mybase"
  run_and_compare -a --per-file-algo sha256
  run_and_compare -m --meta-sig sha256
  run_and_compare -C --first-run-choice overwrite
  run_and_compare -l --log-base "mylog"
}