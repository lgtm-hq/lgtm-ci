#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: results.v1 document (#1080) for reusable-coverage.yml, whose leg
#          runs no tests: counts stay 0 and the merged coverage percentages
#          carry the verdict.
#
# Environment:
#   COVERAGE_PERCENT     (required) Merged lines percentage from collect-coverage
#   COVERAGE_BRANCHES, COVERAGE_FUNCTIONS  (optional) companions
#   THRESHOLD_PASSED     true|false from the threshold gate (status failed when false)
#   MERGED_COVERAGE_FILE (optional) recorded as the coverage artifact
#   RESULTS_OUTPUT       results.v1 path (default results/coverage/default/results.json)
#   RESULTS_SOURCE_VERSION  tooling revision
#
# Outputs: results-json, plus the public outputs results_v1_github_outputs
#   publishes (coverage-percent is read back from the document).

set -euo pipefail

: "${COVERAGE_PERCENT:?COVERAGE_PERCENT is required}"
: "${COVERAGE_BRANCHES:=}"
: "${COVERAGE_FUNCTIONS:=}"
: "${THRESHOLD_PASSED:=true}"
: "${MERGED_COVERAGE_FILE:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing/results.sh
source "$SCRIPT_DIR/../lib/testing/results.sh"

: "${RESULTS_OUTPUT:=$(results_v1_path coverage default)}"

status="passed"
if [[ "$THRESHOLD_PASSED" != "true" ]]; then
	status="failed"
fi
artifacts=""
if [[ -n "$MERGED_COVERAGE_FILE" ]]; then
	artifacts="coverage=${MERGED_COVERAGE_FILE}"$'\n'
fi

mkdir -p "$(dirname "$RESULTS_OUTPUT")"
RESULTS_TOOL=coverage RESULTS_RUNNER=collect-coverage RESULTS_STATUS="$status" \
	COVERAGE_LINES="$COVERAGE_PERCENT" RESULTS_ARTIFACTS="$artifacts" \
	results_v1_build >"$RESULTS_OUTPUT"
results_v1_validate "$RESULTS_OUTPUT"
results_v1_github_outputs "$RESULTS_OUTPUT"
set_github_output "results-json" "$RESULTS_OUTPUT"
log_info "results.v1 written: ${RESULTS_OUTPUT}"
