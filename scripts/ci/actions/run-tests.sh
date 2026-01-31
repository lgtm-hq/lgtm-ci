#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generic test runner that delegates to language-specific runners
#
# Required environment variables:
#   STEP - Which step to run: detect, run, parse, summary
#
# Optional environment variables:
#   RUNNER - Test runner to use: pytest, vitest, playwright, auto (default: auto)
#
# Optional environment variables:
#   CONFIG_FILE - Path to test config file
#   COVERAGE - Whether to collect coverage (true/false)
#   EXTRA_ARGS - Additional arguments to pass to the runner
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
detect)
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	# Guard against set -e exiting on detection failure
	runner=""
	if ! runner=$(detect_test_runner "."); then
		runner="unknown"
	fi
	runner="${runner:-unknown}"

	all_runners=""
	if ! all_runners=$(detect_all_runners "."); then
		all_runners=""
	fi

	log_info "Detected test runner: $runner"
	if [[ -n "$all_runners" ]]; then
		log_info "All available runners: $all_runners"
	fi

	set_github_output "runner" "$runner"
	set_github_output "all-runners" "$all_runners"
	;;

run)
	: "${RUNNER:=auto}"
	: "${WORKING_DIRECTORY:=.}"
	: "${COVERAGE:=false}"
	: "${EXTRA_ARGS:=}"

	cd "$WORKING_DIRECTORY"

	# Auto-detect runner if needed
	if [[ "$RUNNER" == "auto" ]]; then
		if ! RUNNER=$(detect_test_runner "."); then
			RUNNER="unknown"
		fi
		RUNNER="${RUNNER:-unknown}"
		if [[ "$RUNNER" == "unknown" ]]; then
			log_error "Could not auto-detect test runner"
			exit 1
		fi
		log_info "Auto-detected runner: $RUNNER"
	fi

	# Delegate to the appropriate runner
	exit_code=0
	case "$RUNNER" in
	pytest)
		export STEP="run"
		export COVERAGE
		export EXTRA_ARGS
		"$SCRIPT_DIR/run-pytest.sh" || exit_code=$?
		;;
	vitest)
		export STEP="run"
		export COVERAGE
		export EXTRA_ARGS
		"$SCRIPT_DIR/run-vitest.sh" || exit_code=$?
		;;
	playwright)
		export STEP="run"
		export EXTRA_ARGS
		"$SCRIPT_DIR/run-playwright.sh" || exit_code=$?
		;;
	*)
		log_error "Unknown or unsupported runner: $RUNNER"
		exit 1
		;;
	esac

	set_github_output "exit-code" "$exit_code"
	set_github_output "runner" "$RUNNER"

	exit "$exit_code"
	;;

parse)
	: "${RUNNER:=auto}"
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	# Auto-detect runner if needed
	if [[ "$RUNNER" == "auto" ]]; then
		if ! RUNNER=$(detect_test_runner "."); then
			RUNNER="unknown"
		fi
		RUNNER="${RUNNER:-unknown}"
	fi

	# Delegate to the appropriate runner's parse step
	case "$RUNNER" in
	pytest)
		export STEP="parse"
		"$SCRIPT_DIR/run-pytest.sh"
		;;
	vitest)
		export STEP="parse"
		"$SCRIPT_DIR/run-vitest.sh"
		;;
	playwright)
		export STEP="parse"
		"$SCRIPT_DIR/run-playwright.sh"
		;;
	*)
		log_warn "Unknown runner for parsing: $RUNNER"
		set_github_output "tests-passed" "0"
		set_github_output "tests-failed" "0"
		set_github_output "tests-skipped" "0"
		set_github_output "tests-total" "0"
		;;
	esac
	;;

summary)
	: "${RUNNER:=auto}"
	: "${TESTS_PASSED:=0}"
	: "${TESTS_FAILED:=0}"
	: "${TESTS_SKIPPED:=0}"
	: "${TESTS_TOTAL:=0}"
	: "${EXIT_CODE:=0}"

	add_github_summary "## Test Results"
	add_github_summary ""

	if [[ "$TESTS_TOTAL" -eq 0 ]]; then
		add_github_summary "> No tests were found or executed."
	else
		status_icon=""
		if [[ "$EXIT_CODE" -eq 0 ]]; then
			status_icon=":white_check_mark:"
		else
			status_icon=":x:"
		fi

		add_github_summary "| Metric | Value |"
		add_github_summary "|--------|-------|"
		add_github_summary "| **Status** | $status_icon |"
		add_github_summary "| **Runner** | \`$RUNNER\` |"
		add_github_summary "| **Passed** | $TESTS_PASSED |"
		add_github_summary "| **Failed** | $TESTS_FAILED |"
		add_github_summary "| **Skipped** | $TESTS_SKIPPED |"
		add_github_summary "| **Total** | $TESTS_TOTAL |"
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
