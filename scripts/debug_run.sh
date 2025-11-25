#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# Debug runner for process_single_directory
# Usage: ./debug_run.sh
# Writes a self-contained run log and prints its location.

# Resolve script dir and lib dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
LIBDIR="$SCRIPT_DIR/lib"

if [ ! -d "$LIBDIR" ]; then
  echo "ERROR: lib directory not found at $LIBDIR" >&2
  exit 1
fi

# Create output dir (we will create RUN_LOG after sourcing init.sh)
OUTDIR="$(mktemp -d /tmp/debug-process.XXXXXX)"
mkdir -p "$OUTDIR"

{
  echo "DEBUG RUN START"
  echo "SCRIPT_DIR=$SCRIPT_DIR"
  echo "LIBDIR=$LIBDIR"
  echo "OUTDIR=$OUTDIR"
  echo
} > "$OUTDIR/boot.txt"

# Source the modules used by the tests. If any are missing, note and continue.
for f in init.sh logging.sh fs.sh meta.sh process.sh; do
  if [ -f "$LIBDIR/$f" ]; then
    # shellcheck disable=SC1090
    . "$LIBDIR/$f"
    echo "SOURCED: $LIBDIR/$f" >> "$OUTDIR/boot.txt"
  else
    echo "MISSING: $LIBDIR/$f" >> "$OUTDIR/boot.txt"
  fi
done

# Now create and export RUN_LOG (after init.sh so it cannot clobber it)
RUN_LOG="$OUTDIR/run.log"
: > "$RUN_LOG"
export RUN_LOG

# Record some environment info into the run log
{
  echo "SCRIPT_DIR=$SCRIPT_DIR"
  echo "LIBDIR=$LIBDIR"
  echo "OUTDIR=$OUTDIR"
  echo "RUN_LOG=$RUN_LOG"
  echo
} >> "$RUN_LOG"

# Prepare temp test dir
TMPDIR="$(mktemp -d "$OUTDIR/tmp.XXXXXX")"
echo "TMPDIR=$TMPDIR" >> "$RUN_LOG"

# Ensure expected globals are set (mirror test defaults)
BASE_NAME="${BASE_NAME:-#####checksums#####}"
MD5_FILENAME="${MD5_FILENAME:-${BASE_NAME}.md5}"
META_FILENAME="${META_FILENAME:-${BASE_NAME}.meta}"
LOG_FILENAME="${LOG_FILENAME:-${BASE_NAME}.log}"
LOCK_SUFFIX="${LOCK_SUFFIX:-.lock}"

{
  echo "MD5_FILENAME=$MD5_FILENAME"
  echo "META_FILENAME=$META_FILENAME"
  echo "LOG_FILENAME=$LOG_FILENAME"
  echo "LOCK_SUFFIX=$LOCK_SUFFIX"
} >> "$RUN_LOG"

# Create the meta file and the lock exactly like the test does
metaf="$TMPDIR/$META_FILENAME"
lf="${metaf}${LOCK_SUFFIX}"
: > "$metaf"
: > "$lf"

{
  echo "=== PRE-STATE ==="
  echo "metaf: $metaf"
  echo "lock:  $lf"
  echo "ls -la $TMPDIR:"
  ls -la -- "$TMPDIR" || true
  echo
} >> "$RUN_LOG"

# Enable debug flags used by your code
DEBUG=1
export DEBUG

# Trace execution to the run log (makes it easy to see what happens)
{
  echo "=== RUNNING process_single_directory \"$TMPDIR\" ==="
  set -x
  if process_single_directory "$TMPDIR"; then
    echo "process_single_directory exit: 0"
  else
    echo "process_single_directory exit: $?"
  fi
  set +x
  echo "=== DONE ==="
} >> "$RUN_LOG" 2>&1

# Record post-state
{
  echo
  echo "=== POST-STATE ==="
  echo "ls -la $TMPDIR:"
  ls -la -- "$TMPDIR" || true
  echo
  echo "TAIL OF RUN_LOG:"
  tail -n 200 "$RUN_LOG" || true
} >> "$RUN_LOG"

echo "WROTE: $RUN_LOG"
echo "TMPDIR: $TMPDIR"
