#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Amend a results.v1 document after a later step changed the verdict
#          or produced coverage (#1080): a coverage gate that failed the leg,
#          or a coverage percentage parsed after the test parser ran.
#
# Environment:
#   RESULTS_FILE     (required) results.v1 document to amend in place
#   STATUS           (optional) New status (passed|failed|no-tests|error)
#   COVERAGE_LINES   (optional) Lines percentage; non-numeric values (N/A,
#                    empty) are ignored so a missing report never reads as 0%
#   COVERAGE_BRANCHES, COVERAGE_FUNCTIONS  (optional) companions to COVERAGE_LINES
#
# The amended document is re-validated and its public outputs re-published
# (tests-*, status, duration-ms, coverage-percent).

set -euo pipefail

: "${RESULTS_FILE:?RESULTS_FILE is required}"
: "${STATUS:=}"
: "${COVERAGE_LINES:=}"
: "${COVERAGE_BRANCHES:=}"
: "${COVERAGE_FUNCTIONS:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing/results.sh
source "$SCRIPT_DIR/../lib/testing/results.sh"

if [[ ! -f "$RESULTS_FILE" ]]; then
	log_error "results-update: document not found: ${RESULTS_FILE}"
	exit 1
fi

if [[ -n "$STATUS" ]]; then
	results_v1_set_status "$RESULTS_FILE" "$STATUS"
	log_info "results.v1 status set to ${STATUS}: ${RESULTS_FILE}"
fi
if [[ -n "$COVERAGE_LINES" ]]; then
	results_v1_set_coverage "$RESULTS_FILE" "$COVERAGE_LINES" "$COVERAGE_BRANCHES" "$COVERAGE_FUNCTIONS"
	log_info "results.v1 coverage set to ${COVERAGE_LINES}: ${RESULTS_FILE}"
fi

results_v1_github_outputs "$RESULTS_FILE"
