#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run E2E tests using Playwright
#
# Required environment variables:
#   STEP - Which step to run: setup, run, parse, summary
#
# Optional environment variables:
#   PROJECT - Playwright project to run
#   BROWSER - Browser to use: chromium, firefox, webkit, all (default: chromium)
#   REPORTER - Reporter to use: json, html, junit (default: json)
#   SHARD - Shard configuration (e.g., "1/3" for shard 1 of 3)
#   EXTRA_ARGS - Additional arguments to pass to playwright
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
	: "${BROWSER:=chromium}"

	cd "$WORKING_DIRECTORY"

	log_info "Checking Playwright installation..."

	# Check if @playwright/test is installed
	if ! bun pm ls 2>/dev/null | grep -q "@playwright/test"; then
		if [[ -f "package.json" ]]; then
			log_info "Installing dependencies..."
			bun install
		else
			log_info "Installing @playwright/test..."
			bun add -d @playwright/test
		fi
	fi

	# Install browser binaries
	log_info "Installing Playwright browsers..."
	if [[ "$BROWSER" == "all" ]]; then
		bunx playwright install --with-deps
	else
		bunx playwright install --with-deps "$BROWSER"
	fi

	log_success "Playwright setup complete"
	;;

run)
	: "${PROJECT:=}"
	: "${BROWSER:=chromium}"
	: "${REPORTER:=json}"
	: "${SHARD:=}"
	: "${EXTRA_ARGS:=}"
	: "${WORKING_DIRECTORY:=.}"

	cd "$WORKING_DIRECTORY"

	# Build playwright command
	PLAYWRIGHT_ARGS=()
	PLAYWRIGHT_ARGS+=("test")

	# Add project if specified
	if [[ -n "$PROJECT" ]]; then
		PLAYWRIGHT_ARGS+=("--project=$PROJECT")
	fi

	# Add browser filter (only if not using project)
	if [[ -z "$PROJECT" ]] && [[ "$BROWSER" != "all" ]]; then
		PLAYWRIGHT_ARGS+=("--project=$BROWSER")
	fi

	# Add reporter
	case "$REPORTER" in
	json)
		PLAYWRIGHT_ARGS+=("--reporter=json")
		export PLAYWRIGHT_JSON_OUTPUT_NAME="playwright-results.json"
		;;
	html)
		PLAYWRIGHT_ARGS+=("--reporter=html")
		;;
	junit)
		PLAYWRIGHT_ARGS+=("--reporter=junit")
		export PLAYWRIGHT_JUNIT_OUTPUT_NAME="playwright-results.xml"
		;;
	*)
		PLAYWRIGHT_ARGS+=("--reporter=json")
		export PLAYWRIGHT_JSON_OUTPUT_NAME="playwright-results.json"
		;;
	esac

	# Add sharding if specified
	if [[ -n "$SHARD" ]]; then
		PLAYWRIGHT_ARGS+=("--shard=$SHARD")
	fi

	# Add extra args
	if [[ -n "$EXTRA_ARGS" ]]; then
		read -ra EXTRA_ARRAY <<<"$EXTRA_ARGS"
		PLAYWRIGHT_ARGS+=("${EXTRA_ARRAY[@]}")
	fi

	log_info "Running Playwright with args: ${PLAYWRIGHT_ARGS[*]}"

	exit_code=0
	bunx playwright "${PLAYWRIGHT_ARGS[@]}" || exit_code=$?

	# Set outputs
	set_github_output "exit-code" "$exit_code"

	case "$REPORTER" in
	json)
		if [[ -f "playwright-results.json" ]]; then
			set_github_output "report-path" "playwright-results.json"
		fi
		;;
	html)
		if [[ -d "playwright-report" ]]; then
			set_github_output "report-path" "playwright-report"
		fi
		;;
	junit)
		if [[ -f "playwright-results.xml" ]]; then
			set_github_output "report-path" "playwright-results.xml"
		fi
		;;
	esac

	exit "$exit_code"
	;;

parse)
	: "${REPORT_PATH:=playwright-results.json}"
	: "${REPORTER:=json}"

	# Parse test results based on reporter type
	case "$REPORTER" in
	json)
		if [[ -f "$REPORT_PATH" ]]; then
			parse_playwright_json "$REPORT_PATH"

			set_github_output "tests-passed" "$TESTS_PASSED"
			set_github_output "tests-failed" "$TESTS_FAILED"
			set_github_output "tests-skipped" "$TESTS_SKIPPED"
			set_github_output "tests-total" "$TESTS_TOTAL"

			log_info "Test results: $(format_test_summary)"
		else
			log_warn "Results file not found: $REPORT_PATH"
			set_github_output "tests-passed" "0"
			set_github_output "tests-failed" "0"
			set_github_output "tests-skipped" "0"
			set_github_output "tests-total" "0"
		fi
		;;
	junit)
		if [[ -f "$REPORT_PATH" ]]; then
			parse_junit_xml "$REPORT_PATH"

			set_github_output "tests-passed" "$TESTS_PASSED"
			set_github_output "tests-failed" "$TESTS_FAILED"
			set_github_output "tests-skipped" "$TESTS_SKIPPED"
			set_github_output "tests-total" "$TESTS_TOTAL"

			log_info "Test results: $(format_test_summary)"
		else
			log_warn "Results file not found: $REPORT_PATH"
		fi
		;;
	*)
		log_warn "Cannot parse results for reporter: $REPORTER"
		;;
	esac
	;;

summary)
	: "${TESTS_PASSED:=0}"
	: "${TESTS_FAILED:=0}"
	: "${TESTS_SKIPPED:=0}"
	: "${TESTS_TOTAL:=0}"
	: "${BROWSER:=chromium}"
	: "${SHARD:=}"
	: "${EXIT_CODE:=0}"

	add_github_summary "## Playwright E2E Results"
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
		add_github_summary "| Browser | $BROWSER |"
		if [[ -n "$SHARD" ]]; then
			add_github_summary "| Shard | $SHARD |"
		fi
		add_github_summary "| Passed | $TESTS_PASSED |"
		add_github_summary "| Failed | $TESTS_FAILED |"
		add_github_summary "| Skipped | $TESTS_SKIPPED |"
		add_github_summary "| Total | $TESTS_TOTAL |"
	else
		add_github_summary "> No tests were found."
	fi

	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
