#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Testing utilities library aggregator
#
# Sources all testing-related libraries for convenient single-file import.
# Usage: source "scripts/ci/lib/testing.sh"
#
# Loading contract: all testing/* modules are required; sourcing fails loudly
# (returns 1 with an error naming the missing module) when one is absent.

# Guard against multiple sourcing
[[ -n "${_LGTM_CI_TESTING_LOADED:-}" ]] && return 0

# Get the directory of this script
TESTING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)" || {
	echo "testing.sh: cannot resolve library directory" >&2
	return 1
}

# Source all testing sub-libraries in dependency order (all required)
[[ -f "$TESTING_LIB_DIR/testing/detect.sh" ]] || {
	echo "testing.sh: missing required module testing/detect.sh in $TESTING_LIB_DIR" >&2
	return 1
}
# shellcheck source=./testing/detect.sh
source "$TESTING_LIB_DIR/testing/detect.sh" || return 1

[[ -f "$TESTING_LIB_DIR/testing/parse.sh" ]] || {
	echo "testing.sh: missing required module testing/parse.sh in $TESTING_LIB_DIR" >&2
	return 1
}
# shellcheck source=./testing/parse.sh
source "$TESTING_LIB_DIR/testing/parse.sh" || return 1

[[ -f "$TESTING_LIB_DIR/testing/coverage.sh" ]] || {
	echo "testing.sh: missing required module testing/coverage.sh in $TESTING_LIB_DIR" >&2
	return 1
}
# shellcheck source=./testing/coverage.sh
source "$TESTING_LIB_DIR/testing/coverage.sh" || return 1

[[ -f "$TESTING_LIB_DIR/testing/badge.sh" ]] || {
	echo "testing.sh: missing required module testing/badge.sh in $TESTING_LIB_DIR" >&2
	return 1
}
# shellcheck source=./testing/badge.sh
source "$TESTING_LIB_DIR/testing/badge.sh" || return 1

readonly _LGTM_CI_TESTING_LOADED=1
