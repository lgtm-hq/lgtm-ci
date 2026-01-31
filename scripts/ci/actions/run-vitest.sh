#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run JavaScript/TypeScript tests using vitest with optional coverage
#
# Required environment variables:
#   STEP - Which step to run: setup, run, parse, summary
#
# Optional environment variables:
#   TEST_PATH - Path to test files (default: .)
#   COVERAGE - Whether to collect coverage (true/false)
#   COVERAGE_FORMAT - Coverage output format: json, lcov, html (default: json)
#   EXTRA_ARGS - Additional arguments to pass to vitest
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

	log_info "Checking vitest installation..."

	# Check if vitest is available
	if ! bun pm ls 2>/dev/null | grep -q vitest; then
		if [[ -f "package.json" ]]; then
			log_info "Installing dependencies..."
			bun install
		else
			log_info "Installing vitest..."
			bun add -d vitest
		fi
	fi

	# Install coverage provider if needed
	: "${COVERAGE:=false}"
	if [[ "$COVERAGE" == "true" ]]; then
		if ! bun pm ls 2>/dev/null | grep -q "@vitest/coverage-v8"; then
			log_info "Installing @vitest/coverage-v8..."
			bun add -d @vitest/coverage-v8
		fi
	fi

	log_success "vitest setup complete"
	;;

run)
	: "${TEST_PATH:=.}"
	: "${COVERAGE:=false}"
	: "${COVERAGE_FORMAT:=json}"
	: "${EXTRA_ARGS:=}"
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	# Build vitest command
	VITEST_ARGS=()
	VITEST_ARGS+=("run")

	# Add test path if not current directory
	if [[ "$TEST_PATH" != "." ]]; then
		VITEST_ARGS+=("$TEST_PATH")
	fi

	# Add JSON reporter for parsing results
	VITEST_ARGS+=("--reporter=json")
	VITEST_ARGS+=("--outputFile=vitest-results.json")

	# Add coverage options
	if [[ "$COVERAGE" == "true" ]]; then
		VITEST_ARGS+=("--coverage")
		VITEST_ARGS+=("--coverage.reporter=text")
		# Always add json-summary for parse_vitest_coverage
		VITEST_ARGS+=("--coverage.reporter=json-summary")

		# Add user-selected reporter in addition to json-summary
		case "$COVERAGE_FORMAT" in
		json)
			# json-summary already added above
			;;
		lcov)
			VITEST_ARGS+=("--coverage.reporter=lcov")
			;;
		html)
			VITEST_ARGS+=("--coverage.reporter=html")
			;;
		esac
	fi

	# Add extra args
	if [[ -n "$EXTRA_ARGS" ]]; then
		read -ra EXTRA_ARRAY <<<"$EXTRA_ARGS"
		VITEST_ARGS+=("${EXTRA_ARRAY[@]}")
	fi

	log_info "Running vitest with args: ${VITEST_ARGS[*]}"

	exit_code=0
	bun run vitest "${VITEST_ARGS[@]}" || exit_code=$?

	# Set outputs
	set_github_output "exit-code" "$exit_code"

	if [[ -f "vitest-results.json" ]]; then
		set_github_output "results-file" "vitest-results.json"
	fi

	if [[ "$COVERAGE" == "true" ]]; then
		# vitest puts coverage in ./coverage directory by default
		coverage_file=""
		case "$COVERAGE_FORMAT" in
		json) coverage_file="coverage/coverage-summary.json" ;;
		lcov) coverage_file="coverage/lcov.info" ;;
		html) coverage_file="coverage/index.html" ;;
		esac
		if [[ -f "$coverage_file" ]]; then
			set_github_output "coverage-file" "$coverage_file"
		fi
	fi

	exit "$exit_code"
	;;

parse)
	: "${RESULTS_FILE:=vitest-results.json}"
	: "${COVERAGE_FILE:=coverage/coverage-summary.json}"

	# Parse test results
	if [[ -f "$RESULTS_FILE" ]]; then
		parse_vitest_json "$RESULTS_FILE"

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

	# Parse coverage if available
	if [[ -f "$COVERAGE_FILE" ]]; then
		parse_vitest_coverage "$COVERAGE_FILE"
		set_github_output "coverage-percent" "$COVERAGE_PERCENT"
		set_github_output "lines-coverage" "$COVERAGE_LINES"
		set_github_output "branches-coverage" "$COVERAGE_BRANCHES"
		set_github_output "functions-coverage" "$COVERAGE_FUNCTIONS"
		log_info "Coverage: ${COVERAGE_PERCENT}%"
	fi
	;;

summary)
	: "${TESTS_PASSED:=0}"
	: "${TESTS_FAILED:=0}"
	: "${TESTS_SKIPPED:=0}"
	: "${TESTS_TOTAL:=0}"
	: "${COVERAGE_PERCENT:=}"
	: "${EXIT_CODE:=0}"

	add_github_summary "## vitest Results"
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
