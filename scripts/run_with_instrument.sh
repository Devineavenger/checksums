#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./run-with-instrument.sh [--log /tmp/checks-instrument.log] -- checksums-args...
#
# Example:
#   ./run-with-instrument.sh --log /tmp/instr.log -- checksums -p 8 /path/to/test
#
# Behavior:
# - Creates a temporary bin directory and writes wrappers for md5sum and sha256sum.
# - Each wrapper logs start/end lines (ISO8601 UTC) to the instrument log and then execs the real tool.
# - Runs checksums with PATH modified to prefer the wrappers.
# - Cleans up the temporary bin on exit.

INSTR_LOG="/tmp/checksums-instrument.log"
if [ "${1:-}" = "--log" ]; then
  shift
  INSTR_LOG="${1:-/tmp/checksums-instrument.log}"
  shift || true
fi

# Require "--" separator before checksums args
if [ "${1:-}" != "--" ]; then
  echo "Usage: $0 [--log /path/to/log] -- checksums-args..."
  exit 1
fi
shift

CHECKSUMS_CMD=( "$@" )
if [ "${#CHECKSUMS_CMD[@]}" -eq 0 ]; then
  echo "No command provided after --"
  exit 1
fi

TMPBIN="$(mktemp -d)"
cleanup() {
  rm -rf -- "$TMPBIN"
}
trap cleanup EXIT

# Find real binaries (fallback to /usr/bin /bin)
real_md5="$(command -v md5sum || true)"
real_sha256="$(command -v sha256sum || true)"
# On macOS the utility may be "md5" and "shasum -a 256"; try reasonable fallbacks
if [ -z "$real_md5" ]; then
  real_md5="$(command -v md5 || true)"
fi
if [ -z "$real_sha256" ]; then
  real_sha256="$(command -v shasum || true)"
fi

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Wrapper generator: writes a script at $1 that logs and execs real tool
write_wrapper() {
  local path="$1" real="$2" name="$3"
  cat > "$path" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
INSTR_LOG='__INSTR_LOG__'
name='__NAME__'
real='__REAL__'
ts_start="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
# Log invocation: include PID and entire argv (safe quoting)
printf '%s %s START pid=%s args=%s\n' "$ts_start" "$name" "$$" "$(printf '%q ' "$@")" >> "$INSTR_LOG"
# Measure time
t0=$(date +%s.%N 2>/dev/null || date +%s)
# Exec the real tool preserving exit code
if [ -n "$real" ] && [ -x "$real" ]; then
  "$real" "$@"
  rc=$?
else
  # Fallback: try to exec name from PATH (avoid infinite recursion)
  command "$name" "$@"
  rc=$?
fi
t1=$(date +%s.%N 2>/dev/null || date +%s)
# compute duration (may be fractional)
dur="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
ts_end="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf '%s %s END   pid=%s rc=%s dur=%s args=%s\n' "$ts_end" "$name" "$$" "$rc" "$dur" "$(printf '%q ' "$@")" >> "$INSTR_LOG"
exit "$rc"
WRAP
  # Patch placeholders
  sed -i.bak \
    -e "s|__INSTR_LOG__|${INSTR_LOG}|g" \
    -e "s|__NAME__|${name}|g" \
    -e "s|__REAL__|${real}|g" \
    "$path"
  chmod +x "$path"
}

# Create wrappers for known hash command names
if [ -n "$real_md5" ]; then
  write_wrapper "$TMPBIN/md5sum" "$real_md5" "md5sum"
fi
if [ -n "$real_sha256" ]; then
  write_wrapper "$TMPBIN/sha256sum" "$real_sha256" "sha256sum"
fi
# Also wrap "md5" (macOS) and "shasum" if available
real_md5_alt="$(command -v md5 || true)"
real_shasum="$(command -v shasum || true)"
if [ -n "$real_md5_alt" ] && [ ! -e "$TMPBIN/md5" ]; then
  write_wrapper "$TMPBIN/md5" "$real_md5_alt" "md5"
fi
if [ -n "$real_shasum" ] && [ ! -e "$TMPBIN/shasum" ]; then
  write_wrapper "$TMPBIN/shasum" "$real_shasum" "shasum"
fi

# Ensure instrument log exists and is writable
mkdir -p "$(dirname "$INSTR_LOG")"
: > "$INSTR_LOG"

# Run with modified PATH
export PATH="$TMPBIN:$PATH"
echo "Instrumentation log: $INSTR_LOG"
echo "Running: ${CHECKSUMS_CMD[*]}"
"${CHECKSUMS_CMD[@]}"
