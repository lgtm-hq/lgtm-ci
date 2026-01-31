#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Testing utilities library aggregator
#
# Sources all testing-related libraries for convenient single-file import.
# Usage: source "scripts/ci/lib/testing.sh"

# Guard against multiple sourcing
[[ -n "${_LGTM_CI_TESTING_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_LOADED=1

# Get the directory of this script
TESTING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all testing sub-libraries in dependency order
# shellcheck source=./testing/detect.sh
source "$TESTING_LIB_DIR/testing/detect.sh"

# shellcheck source=./testing/parse.sh
source "$TESTING_LIB_DIR/testing/parse.sh"

# shellcheck source=./testing/coverage.sh
source "$TESTING_LIB_DIR/testing/coverage.sh"

# shellcheck source=./testing/badge.sh
source "$TESTING_LIB_DIR/testing/badge.sh"
