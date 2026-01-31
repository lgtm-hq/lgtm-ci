#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run Python tests using pytest with optional coverage
#
# Required environment variables:
#   STEP - Which step to run: setup, run, parse, summary
#
# Optional environment variables:
#   TEST_PATH - Path to test files (default: tests)
#   COVERAGE - Whether to collect coverage (true/false)
#   COVERAGE_FORMAT - Coverage output format: xml, json, lcov (default: json)
#   MARKERS - pytest markers to filter tests (e.g., "not slow")
#   EXTRA_ARGS - Additional arguments to pass to pytest
#   WORKING_DIRECTORY - Directory to run tests in

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing.sh
source "$SCRIPT_DIR/../lib/testing.sh"

case "$STEP" in
setup)
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	log_info "Checking pytest installation..."

	# Check for both pytest and pytest-json-report
	if ! uv run python -c "import pytest; import pytest_jsonreport" 2>/dev/null; then
		log_info "Installing pytest and pytest-json-report..."
		uv pip install pytest pytest-json-report
	fi

	# Install coverage plugin if needed
	: "${COVERAGE:=false}"
	if [[ "$COVERAGE" == "true" ]]; then
		if ! uv run python -c "import pytest_cov" 2>/dev/null; then
			log_info "Installing pytest-cov..."
			uv pip install pytest-cov
		fi
	fi

	log_success "pytest setup complete"
	;;

run)
	: "${TEST_PATH:=tests}"
	: "${COVERAGE:=false}"
	: "${COVERAGE_FORMAT:=json}"
	: "${COVERAGE_SOURCE:=}"
	: "${MARKERS:=}"
	: "${EXTRA_ARGS:=}"
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	# Build pytest command
	PYTEST_ARGS=()
	PYTEST_ARGS+=("$TEST_PATH")

	# Add JSON report for parsing results
	PYTEST_ARGS+=("--json-report" "--json-report-file=pytest-results.json")

	# Add coverage options
	if [[ "$COVERAGE" == "true" ]]; then
		if [[ -n "$COVERAGE_SOURCE" ]]; then
			PYTEST_ARGS+=("--cov=$COVERAGE_SOURCE" "--cov-report=term")
		else
			PYTEST_ARGS+=("--cov" "--cov-report=term")
		fi

		case "$COVERAGE_FORMAT" in
		xml)
			PYTEST_ARGS+=("--cov-report=xml:coverage.xml")
			;;
		json)
			PYTEST_ARGS+=("--cov-report=json:coverage.json")
			;;
		lcov)
			PYTEST_ARGS+=("--cov-report=lcov:coverage.lcov")
			;;
		*)
			log_warn "Unknown COVERAGE_FORMAT '$COVERAGE_FORMAT', defaulting to json"
			PYTEST_ARGS+=("--cov-report=json:coverage.json")
			;;
		esac
	fi

	# Add markers if specified
	if [[ -n "$MARKERS" ]]; then
		PYTEST_ARGS+=("-m" "$MARKERS")
	fi

	# Add extra args
	if [[ -n "$EXTRA_ARGS" ]]; then
		# Split extra args by spaces (respecting quotes would need more complex parsing)
		read -ra EXTRA_ARRAY <<<"$EXTRA_ARGS"
		PYTEST_ARGS+=("${EXTRA_ARRAY[@]}")
	fi

	log_info "Running pytest with args: ${PYTEST_ARGS[*]}"

	exit_code=0
	uv run pytest "${PYTEST_ARGS[@]}" || exit_code=$?

	# Set outputs
	set_github_output "exit-code" "$exit_code"

	if [[ -f "pytest-results.json" ]]; then
		set_github_output "results-file" "pytest-results.json"
	fi

	if [[ "$COVERAGE" == "true" ]]; then
		coverage_file=""
		case "$COVERAGE_FORMAT" in
		xml) coverage_file="coverage.xml" ;;
		json) coverage_file="coverage.json" ;;
		lcov) coverage_file="coverage.lcov" ;;
		*) coverage_file="coverage.json" ;; # Match the default from earlier
		esac
		if [[ -f "$coverage_file" ]]; then
			set_github_output "coverage-file" "$coverage_file"
		fi
	fi

	exit "$exit_code"
	;;

parse)
	: "${RESULTS_FILE:=pytest-results.json}"
	: "${COVERAGE_FILE:=}"

	# Parse test results
	if [[ -f "$RESULTS_FILE" ]]; then
		parse_pytest_json "$RESULTS_FILE"

		set_github_output "tests-passed" "$TESTS_PASSED"
		set_github_output "tests-failed" "$TESTS_FAILED"
		set_github_output "tests-skipped" "$TESTS_SKIPPED"
		set_github_output "tests-total" "$TESTS_TOTAL"

		log_info "Test results: $(format_test_summary)"
	else
		log_warn "Results file not found: $RESULTS_FILE"
		set_github_output "tests-passed" "0"
		set_github_output "tests-failed" "0"
		set_github_output "tests-skipped" "0"
		set_github_output "tests-total" "0"
	fi

	# Parse coverage if explicitly provided and file exists
	if [[ -n "$COVERAGE_FILE" ]] && [[ -f "$COVERAGE_FILE" ]]; then
		coverage_percent=$(extract_coverage_percent "$COVERAGE_FILE")
		set_github_output "coverage-percent" "$coverage_percent"
		log_info "Coverage: ${coverage_percent}%"
	fi
	;;

summary)
	: "${TESTS_PASSED:=0}"
	: "${TESTS_FAILED:=0}"
	: "${TESTS_SKIPPED:=0}"
	: "${TESTS_TOTAL:=0}"
	: "${COVERAGE_PERCENT:=}"
	: "${EXIT_CODE:=0}"

	add_github_summary "## pytest Results"
	add_github_summary ""

	status_icon=""
	if [[ "$EXIT_CODE" -eq 0 ]]; then
		status_icon=":white_check_mark: Passed"
	else
		status_icon=":x: Failed"
	fi

	add_github_summary "**Status:** $status_icon"
	add_github_summary ""

	if [[ "$TESTS_TOTAL" -gt 0 ]]; then
		add_github_summary "| Metric | Value |"
		add_github_summary "|--------|-------|"
		add_github_summary "| Passed | $TESTS_PASSED |"
		add_github_summary "| Failed | $TESTS_FAILED |"
		add_github_summary "| Skipped | $TESTS_SKIPPED |"
		add_github_summary "| Total | $TESTS_TOTAL |"

		if [[ -n "$COVERAGE_PERCENT" ]]; then
			add_github_summary "| Coverage | ${COVERAGE_PERCENT}% |"
		fi
	else
		add_github_summary "> No tests were found."
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
