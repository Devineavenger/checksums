#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/tools.sh'
load '../lib/logging.sh'

setup() {
  TMPDIR=$(mktemp -d)
  LIBDIR="$BATS_TEST_DIRNAME/../lib"
}

teardown() { rm -rf "$TMPDIR"; }

@test "check_required_tools fails when md5 missing" {
  PER_FILE_ALGO="md5"
  TOOL_md5_cmd=""
  run check_required_tools
  [ "$status" -eq 1 ]
}

@test "detect_tools picks shasum when sha256sum absent (subshell PATH)" {
  # Create a shasum stub in TMPDIR so sha256sum is truly absent
  cat >"$TMPDIR/shasum" <<'EOF'
#!/bin/sh
# simple stub that behaves like shasum -a 256
echo "fake shasum"
exit 0
EOF
  chmod +x "$TMPDIR/shasum"

  # Build a minimal toolchain dir for the subshell so libs can be sourced
  MINIBIN="$TMPDIR/bin"
  mkdir -p "$MINIBIN"

  link_tool() {
    local name="$1"
    if [ -x "/bin/$name" ]; then
      ln -sf "/bin/$name" "$MINIBIN/$name"
    elif [ -x "/usr/bin/$name" ]; then
      ln -sf "/usr/bin/$name" "$MINIBIN/$name"
    fi
  }

  # Ensure core utilities the libs need are available inside MINIBIN
  for t in dirname basename grep awk sed cut sort tr date printf; do
    link_tool "$t"
  done

  # Also ensure shasum is available on the restricted PATH by placing a copy in MINIBIN
  cp "$TMPDIR/shasum" "$MINIBIN/shasum"
  chmod +x "$MINIBIN/shasum"

  # Run detection in a subshell with an isolated PATH (no system dirs).
  # Use absolute /bin/bash and disable profile/rc loading to avoid noisy /etc/profile.d.
  output=$(
    env PATH="$MINIBIN:$TMPDIR" /bin/bash --noprofile --norc -lc '
      set -euo pipefail

      # Sanity: verify sha256sum is absent and shasum present
      printf "SANITY sha256sum=%s\n" "$(command -v sha256sum || echo absent)"
      printf "SANITY shasum=%s\n"    "$(command -v shasum || echo absent)"

      # Source the libs using the outer LIBDIR (expanded by the outer shell)
      . "'"$LIBDIR"'/init.sh"
      . "'"$LIBDIR"'/logging.sh"
      . "'"$LIBDIR"'/tools.sh"

      TOOL_sha256=""; TOOL_shasum=""
      detect_tools

      printf "RESULT TOOL_sha256=%s\n" "${TOOL_sha256:-}"
      printf "RESULT TOOL_shasum=%s\n" "${TOOL_shasum:-}"
    '
  ) || inner_rc=$?

  if [ -n "${inner_rc:-}" ] && [ "${inner_rc}" -ne 0 ]; then
    echo "INNER_SUBSHELL_RC=${inner_rc}"
    echo "INNER_OUTPUT_START"
    printf '%s\n' "$output"
    echo "INNER_OUTPUT_END"
    false
  fi

  # Assertions: sanity lines must indicate sha256sum absent and shasum found
  [[ "$output" == *"SANITY sha256sum=absent"* ]]
  [[ "$output" == *"SANITY shasum="* ]]

  # Robust extraction: split on '=' only, then trim leading whitespace
  selected_sha256=$(printf "%s\n" "$output" | awk -F'=' '/^RESULT TOOL_sha256=/ {sub(/^[[:space:]]+/,"",$2); print $2}')
  selected_shasum=$(printf "%s\n" "$output" | awk -F'=' '/^RESULT TOOL_shasum=/ {sub(/^[[:space:]]+/,"",$2); print $2}')

  # sha256 should be empty (absent), shasum should be set
  [ -z "$selected_sha256" ]
  [ -n "$selected_shasum" ]
}
