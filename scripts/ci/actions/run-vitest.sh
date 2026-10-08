#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run JavaScript/TypeScript tests using vitest with optional coverage
#
# Required environment variables:
#   STEP - Which step to run: setup, run, parse, summary
#   PACKAGE_MANAGER - bun, npm, or pnpm (setup and run steps; never inferred
#                     from lockfiles, see lib/node/pm.sh)
#
# Optional environment variables:
#   TEST_PATH - Path to test files (default: .)
#   COVERAGE - Whether to collect coverage (true/false)
#   COVERAGE_FORMAT - Coverage output format: json, lcov, html (default: json)
#   EXTRA_ARGS - Additional arguments to pass to vitest
#   WORKING_DIRECTORY - Directory to run tests in
#   EXIT_CODE - vitest exit code (parse step; feeds results.v1 status)
#   MATRIX_KEY / MATRIX_VALUE - matrix coordinate recorded in results.v1
#   RESULTS_OUTPUT - results.v1 path (default results/vitest/<matrix-value|default>/results.json)
#   RESULTS_FILE - summary step: results.v1 document to render
#
# Test tooling is a consumer prerequisite: vitest (and a coverage provider
# when COVERAGE=true) must already be in the installed tree. The setup step
# fails with an actionable message instead of installing anything (#1077).

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing.sh
source "$SCRIPT_DIR/../lib/testing.sh"
# shellcheck source=../lib/node/pm.sh
source "$SCRIPT_DIR/../lib/node/pm.sh"

case "$STEP" in
setup)
	: "${WORKING_DIRECTORY:=.}"
	: "${COVERAGE:=false}"

	cd "$WORKING_DIRECTORY"

	pm_require >/dev/null || exit $?

	log_info "Checking vitest installation (${PACKAGE_MANAGER})..."

	if ! pm_has vitest; then
		die "vitest is not installed in $(pwd): install vitest as a devDependency and commit the ${PACKAGE_MANAGER} lockfile"
	fi

	if [[ "$COVERAGE" == "true" ]]; then
		if ! pm_has @vitest/coverage-v8 && ! pm_has @vitest/coverage-istanbul; then
			die "coverage=true needs a vitest coverage provider: install @vitest/coverage-v8 (or @vitest/coverage-istanbul) as a devDependency and commit the ${PACKAGE_MANAGER} lockfile"
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

	pm_require >/dev/null || exit $?

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
	pm_exec vitest "${VITEST_ARGS[@]}" || exit_code=$?

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
	: "${EXIT_CODE:=}"
	: "${MATRIX_KEY:=}"
	: "${MATRIX_VALUE:=}"
	: "${RESULTS_OUTPUT:=$(results_v1_path vitest "${MATRIX_VALUE:-default}")}"

	# Native report (+ istanbul summary) -> results.v1 (#1080). Every public
	# output below is read back from that document, never from parser state.
	artifacts=""
	if [[ -f "$RESULTS_FILE" ]]; then
		artifacts+="report=${RESULTS_FILE}"$'\n'
	else
		log_warn "Results file not found: $RESULTS_FILE"
	fi
	if [[ -f "$COVERAGE_FILE" ]]; then
		artifacts+="coverage=${COVERAGE_FILE}"$'\n'
	fi

	mkdir -p "$(dirname "$RESULTS_OUTPUT")"
	RESULTS_ARTIFACTS="$artifacts" vitest_results_v1 "$RESULTS_FILE" "$COVERAGE_FILE" >"$RESULTS_OUTPUT"
	results_v1_validate "$RESULTS_OUTPUT"
	results_v1_github_outputs "$RESULTS_OUTPUT"
	set_github_output "results-json" "$RESULTS_OUTPUT"

	log_info "Test results: $(format_test_summary)"
	if [[ -n "$COVERAGE_LINES" ]]; then
		# Per-metric outputs kept for callers that read them directly.
		set_github_output "lines-coverage" "$COVERAGE_LINES"
		set_github_output "branches-coverage" "${COVERAGE_BRANCHES:-0}"
		set_github_output "functions-coverage" "${COVERAGE_FUNCTIONS:-0}"
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
		COVERAGE_LINES="${COVERAGE_PERCENT:-}" RESULTS_TOOL=vitest RESULTS_RUNNER=run-vitest \
			EXIT_CODE="${EXIT_CODE:-0}" results_v1_build >"$RESULTS_FILE"
	fi
	TITLE="vitest Results" RESULTS_FILE="$RESULTS_FILE" \
		bash "$SCRIPT_DIR/render-step-summary.sh"
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
