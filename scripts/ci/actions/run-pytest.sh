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
#   EXIT_CODE - pytest exit code (parse step; feeds results.v1 status)
#   MATRIX_KEY / MATRIX_VALUE - matrix coordinate recorded in results.v1
#   RESULTS_OUTPUT - results.v1 path (default results/pytest/<matrix-value|default>/results.json)
#   RESULTS_FILE - summary step: results.v1 document to render

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
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
	if ! uv run --frozen python -c "import pytest; import pytest_jsonreport" 2>/dev/null; then
		log_info "Installing pytest and pytest-json-report..."
		uv pip install pytest pytest-json-report
	fi

	# Install coverage plugin if needed
	: "${COVERAGE:=false}"
	if [[ "$COVERAGE" == "true" ]]; then
		if ! uv run --frozen python -c "import pytest_cov" 2>/dev/null; then
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
	uv run --frozen pytest "${PYTEST_ARGS[@]}" || exit_code=$?

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
	: "${EXIT_CODE:=}"
	: "${MATRIX_KEY:=}"
	: "${MATRIX_VALUE:=}"
	: "${RESULTS_OUTPUT:=$(results_v1_path pytest "${MATRIX_VALUE:-default}")}"

	# Native report (+ coverage file) -> results.v1 (#1080). Every public
	# output below is read back from that document, never from parser state.
	artifacts=""
	if [[ -f "$RESULTS_FILE" ]]; then
		artifacts+="report=${RESULTS_FILE}"$'\n'
	else
		log_warn "Results file not found: $RESULTS_FILE"
	fi
	if [[ -n "$COVERAGE_FILE" ]]; then
		if [[ -f "$COVERAGE_FILE" ]]; then
			artifacts+="coverage=${COVERAGE_FILE}"$'\n'
		else
			log_warn "Coverage file not found: $COVERAGE_FILE"
		fi
	fi

	mkdir -p "$(dirname "$RESULTS_OUTPUT")"
	RESULTS_ARTIFACTS="$artifacts" pytest_results_v1 "$RESULTS_FILE" "$COVERAGE_FILE" >"$RESULTS_OUTPUT"
	results_v1_validate "$RESULTS_OUTPUT"
	results_v1_github_outputs "$RESULTS_OUTPUT"
	set_github_output "results-json" "$RESULTS_OUTPUT"

	log_info "Test results: $(format_test_summary)"
	if [[ -n "$COVERAGE_LINES" ]]; then
		log_info "Coverage: ${COVERAGE_LINES}%"
	fi
	log_info "results.v1 written: ${RESULTS_OUTPUT}"
	;;

summary)
	# Pure renderer over the contract document. The legacy TESTS_* /
	# COVERAGE_PERCENT / EXIT_CODE inputs are still accepted: without
	# RESULTS_FILE they are folded into a temporary document first.
	: "${RESULTS_FILE:=}"
	if [[ -z "$RESULTS_FILE" || ! -f "$RESULTS_FILE" ]]; then
		RESULTS_FILE="$(mktemp)"
		COVERAGE_LINES="${COVERAGE_PERCENT:-}" RESULTS_TOOL=pytest RESULTS_RUNNER=run-pytest \
			EXIT_CODE="${EXIT_CODE:-0}" results_v1_build >"$RESULTS_FILE"
	fi
	TITLE="pytest Results" RESULTS_FILE="$RESULTS_FILE" \
		bash "$SCRIPT_DIR/render-step-summary.sh"
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
