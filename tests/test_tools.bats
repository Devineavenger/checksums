#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/logging.sh'
load '../lib/tools.sh'

setup() { :; }
teardown() { :; }

@test "detect_tools sets md5 command" {
  detect_tools
  [ -n "$TOOL_md5_cmd" ]
}

@test "check_required_tools fails if algo missing" {
  PER_FILE_ALGO="sha256"
  TOOL_sha256=""
  TOOL_shasum=""
  run check_required_tools
  [ "$status" -eq 1 ]
}
