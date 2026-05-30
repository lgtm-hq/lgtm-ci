#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Parse nextest JUnit XML and optional LCOV coverage for Rust test workflows.
#
# Environment variables:
#   JUNIT_FILE - Path to JUnit XML from nextest (required)
#   LCOV_FILE - Path to LCOV report when coverage mode ran (optional)
#   COVERAGE_ENABLED - true when coverage was requested for this run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../../lib/actions.sh
source "$SCRIPT_DIR/../../lib/actions.sh"
# shellcheck source=../../lib/testing/parse/junit.sh
source "$SCRIPT_DIR/../../lib/testing/parse/junit.sh"
# shellcheck source=../../lib/testing/coverage/extract.sh
source "$SCRIPT_DIR/../../lib/testing/coverage/extract.sh"

: "${JUNIT_FILE:=target/nextest/ci/junit.xml}"
: "${LCOV_FILE:=}"
: "${COVERAGE_ENABLED:=false}"

if [[ ! -f "$JUNIT_FILE" ]]; then
	log_error "JUnit file not found: $JUNIT_FILE"
	log_error "Ensure .config/nextest.toml defines [profile.ci.junit] (see examples/nextest-ci.toml)"
	exit 1
fi

if ! parse_junit_xml "$JUNIT_FILE"; then
	log_error "Failed to parse JUnit XML at $JUNIT_FILE"
	exit 1
fi

set_github_output "tests-passed" "$TESTS_PASSED"
set_github_output "tests-failed" "$TESTS_FAILED"
set_github_output "tests-skipped" "$TESTS_SKIPPED"
set_github_output "tests-total" "$TESTS_TOTAL"

if [[ "$TESTS_TOTAL" -gt 0 ]] || [[ "$TESTS_SKIPPED" -gt 0 ]]; then
	set_github_output "tests-ran" "true"
else
	set_github_output "tests-ran" "false"
fi

if [[ "$COVERAGE_ENABLED" == "true" && -f "$LCOV_FILE" ]]; then
	if coverage_percent="$(extract_coverage_percent "$LCOV_FILE")"; then
		set_github_output "coverage-percent" "$coverage_percent"
		log_info "Coverage: ${coverage_percent}%"
	else
		log_warning "Failed to extract coverage percent from $LCOV_FILE"
	fi
fi

log_info "Parsed tests: passed=$TESTS_PASSED failed=$TESTS_FAILED skipped=$TESTS_SKIPPED total=$TESTS_TOTAL"
