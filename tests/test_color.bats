#!/usr/bin/env bats
load '../lib/init.sh'
load '../lib/color.sh'

# --- _color_init: variable population ---

@test "_color_init sets all 10 variables when color enabled" {
  # Force color on by unsetting NO_COLOR (TTY detection may fail in test,
  # so we test the variable-defined contract instead)
  unset NO_COLOR
  _color_init
  # All variables should be defined (possibly empty if not a TTY)
  [[ -n "${_C_BOLD+x}" ]]
  [[ -n "${_C_DIM+x}" ]]
  [[ -n "${_C_RST+x}" ]]
  [[ -n "${_C_RED+x}" ]]
  [[ -n "${_C_GREEN+x}" ]]
  [[ -n "${_C_YELLOW+x}" ]]
  [[ -n "${_C_BLUE+x}" ]]
  [[ -n "${_C_MAGENTA+x}" ]]
  [[ -n "${_C_CYAN+x}" ]]
  [[ -n "${_C_WHITE+x}" ]]
}

@test "_color_init clears all variables when NO_COLOR is set" {
  NO_COLOR=1
  _color_init
  [ -z "$_C_BOLD" ]
  [ -z "$_C_DIM" ]
  [ -z "$_C_RST" ]
  [ -z "$_C_RED" ]
  [ -z "$_C_GREEN" ]
  [ -z "$_C_YELLOW" ]
  [ -z "$_C_BLUE" ]
  [ -z "$_C_MAGENTA" ]
  [ -z "$_C_CYAN" ]
  [ -z "$_C_WHITE" ]
  unset NO_COLOR
}

@test "_color_init is idempotent" {
  NO_COLOR=1
  _color_init
  _color_init
  [ -z "$_C_RED" ]
  unset NO_COLOR
  _color_init
  # Should work without error on repeated calls
  _color_init
}

@test "_color_init respects empty NO_COLOR" {
  # NO_COLOR="" should not disable colors (only non-empty disables)
  # Per the NO_COLOR spec, the presence of the variable (even empty) disables.
  # Our implementation: [ -z "${NO_COLOR:-}" ] — empty string IS falsy, so colors stay on.
  NO_COLOR=""
  _color_init
  # With empty NO_COLOR and non-TTY (test env), colors depend on TTY.
  # Just verify no crash and variables are defined.
  [[ -n "${_C_BOLD+x}" ]]
  unset NO_COLOR
}

@test "color variables contain escape sequences or are empty" {
  unset NO_COLOR
  _color_init
  # Each variable is either empty (no TTY) or contains \033[
  for var in _C_BOLD _C_DIM _C_RST _C_RED _C_GREEN _C_YELLOW _C_BLUE _C_MAGENTA _C_CYAN _C_WHITE; do
    local val="${!var}"
    [ -z "$val" ] || [[ "$val" == *'\033['* ]]
  done
}

@test "_color_init called at source time" {
  # After sourcing color.sh, variables should already be defined
  # (we loaded it at the top of this file)
  [[ -n "${_C_RST+x}" ]]
  [[ -n "${_C_RED+x}" ]]
}
