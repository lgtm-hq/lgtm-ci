#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Coverage utilities library aggregator
#
# Sources all coverage-related sub-modules for convenient single-file import.
# Usage: source "scripts/ci/lib/testing/coverage.sh"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_COVERAGE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_COVERAGE_LOADED=1

# Get directory of this script
_LGTM_CI_TESTING_COV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all coverage sub-modules in dependency order
# shellcheck source=./coverage/extract.sh
source "$_LGTM_CI_TESTING_COV_DIR/coverage/extract.sh"

# shellcheck source=./coverage/merge.sh
source "$_LGTM_CI_TESTING_COV_DIR/coverage/merge.sh"

# shellcheck source=./coverage/threshold.sh
source "$_LGTM_CI_TESTING_COV_DIR/coverage/threshold.sh"
