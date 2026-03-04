#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-SourceAvailable-NoRedistribution-NoCommercial-NoDerivatives
# Copyright (c) 2025 Alexandru Barbu
#
# Permission is granted to use, study, and modify this software for personal, educational, or internal purposes only.
# Redistribution, commercial use, and distribution of modified versions or derivative works are prohibited.
#
# This software is provided "as is," without warranty of any kind. The author shall not be liable for any damages
# arising from its use.

# shellcheck disable=SC2034

# color.sh
#
# Shared color palette for all console output.
#
# Provides 10 global variables (7 colors + bold + dim + reset) that every
# module can use for user-facing terminal output.  Colors are auto-enabled
# when stdout is a TTY and the NO_COLOR environment variable is unset.
#
# Loaded before all other modules (alphabetical glob order: color < compat < fs …).

_color_init() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _C_BOLD='\033[1m'
    _C_DIM='\033[2m'
    _C_RST='\033[0m'
    _C_RED='\033[31m'
    _C_GREEN='\033[32m'
    _C_YELLOW='\033[33m'
    _C_BLUE='\033[34m'
    _C_MAGENTA='\033[35m'
    _C_CYAN='\033[36m'
    _C_WHITE='\033[37m'
  else
    _C_BOLD='' _C_DIM='' _C_RST=''
    _C_RED='' _C_GREEN='' _C_YELLOW=''
    _C_BLUE='' _C_MAGENTA='' _C_CYAN='' _C_WHITE=''
  fi
}

# Initialize at source time so all later modules have colors available.
_color_init
