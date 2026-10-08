#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Parse nextest JUnit XML and optional LCOV coverage for Rust test workflows.
#
# Writes the results.v1 document (#1080) and derives every public output
# from it.
#
# Environment variables:
#   JUNIT_FILE - Path to JUnit XML from nextest (required)
#   LCOV_FILE - Path to LCOV report when coverage mode ran (optional)
#   COVERAGE_ENABLED - true when coverage was requested for this run
#   EXIT_CODE - nextest exit code (optional; feeds results.v1 status)
#   MATRIX_KEY / MATRIX_VALUE - matrix coordinate recorded in results.v1
#   RESULTS_OUTPUT - results.v1 path (default results/nextest/<matrix-value|default>/results.json)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/testing/results.sh
source "$SCRIPT_DIR/../../lib/testing/results.sh"
# shellcheck source=../../lib/testing/parse/junit.sh
source "$SCRIPT_DIR/../../lib/testing/parse/junit.sh"
# shellcheck source=../../lib/testing/coverage/extract.sh
source "$SCRIPT_DIR/../../lib/testing/coverage/extract.sh"

: "${JUNIT_FILE:=target/nextest/ci/junit.xml}"
: "${LCOV_FILE:=}"
: "${COVERAGE_ENABLED:=false}"
: "${EXIT_CODE:=}"
: "${MATRIX_KEY:=}"
: "${MATRIX_VALUE:=}"
: "${RESULTS_OUTPUT:=$(results_v1_path nextest "${MATRIX_VALUE:-default}")}"

coverage_input=""
artifacts=""
if [[ -f "$JUNIT_FILE" ]]; then
	artifacts+="junit=${JUNIT_FILE}"$'\n'
fi
if [[ "$COVERAGE_ENABLED" == "true" && -n "$LCOV_FILE" && -f "$LCOV_FILE" ]]; then
	coverage_input="$LCOV_FILE"
	artifacts+="coverage=${LCOV_FILE}"$'\n'
fi

# The document is written first, even for a missing report (status error),
# so the artifact upload and the aggregate see the failure instead of a gap.
mkdir -p "$(dirname "$RESULTS_OUTPUT")"
RESULTS_TOOL=cargo-nextest RESULTS_RUNNER=run-rust-nextest RESULTS_ARTIFACTS="$artifacts" \
	junit_results_v1 "$JUNIT_FILE" "$coverage_input" >"$RESULTS_OUTPUT"
results_v1_validate "$RESULTS_OUTPUT"
set_github_output "results-json" "$RESULTS_OUTPUT"

if [[ ! -f "$JUNIT_FILE" ]]; then
	log_error "JUnit file not found: $JUNIT_FILE"
	log_error "Ensure .config/nextest.toml defines [profile.ci.junit] (see examples/nextest-ci.toml)"
	exit 1
fi
if [[ "$(jq -r .status "$RESULTS_OUTPUT")" == "error" ]]; then
	log_error "Failed to parse JUnit XML at $JUNIT_FILE"
	exit 1
fi

IFS=$'\t' read -r tests_passed tests_failed tests_skipped < <(
	jq -r '[.counts.passed, .counts.failed, .counts.skipped] | @tsv' "$RESULTS_OUTPUT"
)

# Exclude skipped tests from PR comment pass-rate denominator (matches legacy cargo parser).
# results.v1 counts.total keeps the true total; only this output narrows it.
tests_total_for_comment=$((tests_passed + tests_failed))

set_github_output "tests-passed" "$tests_passed"
set_github_output "tests-failed" "$tests_failed"
set_github_output "tests-skipped" "$tests_skipped"
set_github_output "tests-total" "$tests_total_for_comment"
set_github_output "status" "$(jq -r .status "$RESULTS_OUTPUT")"

if [[ "$tests_total_for_comment" -gt 0 ]] || [[ "$tests_skipped" -gt 0 ]]; then
	set_github_output "tests-ran" "true"
else
	set_github_output "tests-ran" "false"
fi

if [[ "$COVERAGE_ENABLED" == "true" ]]; then
	if [[ ! -f "$LCOV_FILE" ]]; then
		log_error "LCOV file not found: $LCOV_FILE"
		exit 1
	fi
	coverage_percent="$(jq -r '.coverage.lines // empty' "$RESULTS_OUTPUT")"
	if [[ -n "$coverage_percent" ]]; then
		set_github_output "coverage-percent" "$coverage_percent"
		log_info "Coverage: ${coverage_percent}%"
	else
		log_error "Failed to extract coverage percent from $LCOV_FILE"
		exit 1
	fi
fi

log_info "Parsed tests: passed=$tests_passed failed=$tests_failed skipped=$tests_skipped total=$tests_total_for_comment"
log_info "results.v1 written: ${RESULTS_OUTPUT}"
