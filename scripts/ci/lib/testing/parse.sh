#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Test result parsing utilities library aggregator
#
# Sources all parsing-related sub-modules for convenient single-file import.
# Usage: source "scripts/ci/lib/testing/parse.sh"

# Prevent multiple sourcing
[[ -n "${_LGTM_CI_TESTING_PARSE_LOADED:-}" ]] && return 0
readonly _LGTM_CI_TESTING_PARSE_LOADED=1

# Get directory of this script
_LGTM_CI_TESTING_PARSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all parse sub-modules
# shellcheck source=./parse/common.sh
source "$_LGTM_CI_TESTING_PARSE_DIR/parse/common.sh"

# shellcheck source=./parse/pytest.sh
source "$_LGTM_CI_TESTING_PARSE_DIR/parse/pytest.sh"

# shellcheck source=./parse/vitest.sh
source "$_LGTM_CI_TESTING_PARSE_DIR/parse/vitest.sh"

# shellcheck source=./parse/playwright.sh
source "$_LGTM_CI_TESTING_PARSE_DIR/parse/playwright.sh"

# shellcheck source=./parse/junit.sh
source "$_LGTM_CI_TESTING_PARSE_DIR/parse/junit.sh"
