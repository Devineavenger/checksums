#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/tools.sh'
load '../lib/logging.sh'

setup() {
  TMPDIR=$(mktemp -d)
  echo '#!/bin/sh; echo fake-shasum' > "$TMPDIR/shasum"
  chmod +x "$TMPDIR/shasum"
  PATH="$TMPDIR:$PATH"
}

teardown() { rm -rf "$TMPDIR"; }

@test "check_required_tools fails when md5 missing" {
  PER_FILE_ALGO="md5"
  TOOL_md5_cmd=""
  run check_required_tools
  [ "$status" -eq 1 ]
}

@test "detect_tools picks shasum when sha256sum absent" {
  TOOL_sha256=""
  TOOL_shasum=""
  detect_tools
  [ -n "$TOOL_shasum" ]
}
