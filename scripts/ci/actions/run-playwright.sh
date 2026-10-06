#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run E2E tests using Playwright
#
# Required environment variables:
#   STEP - Which step to run: setup, run, parse, summary
#   PACKAGE_MANAGER - bun, npm, or pnpm (setup and run steps; never inferred
#                     from lockfiles, see lib/node/pm.sh)
#
# Optional environment variables:
#   PROJECT - Playwright project to run
#   BROWSER - Browser to use: chromium, firefox, webkit, all (default: chromium)
#   REPORTER - Reporter to use: json, html, junit (default: json)
#   SHARD - Shard configuration (e.g., "1/3" for shard 1 of 3)
#   EXTRA_ARGS - Additional arguments to pass to playwright
#   WORKING_DIRECTORY - Directory to run tests in
#
# @playwright/test is a consumer prerequisite: the setup step installs browser
# binaries (outside the project tree) but never the package itself (#1077).

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
	: "${BROWSER:=chromium}"

	cd "$WORKING_DIRECTORY"

	pm_require >/dev/null || exit $?

	log_info "Checking Playwright installation (${PACKAGE_MANAGER})..."

	if ! pm_has @playwright/test; then
		die "@playwright/test is not installed in $(pwd): install @playwright/test as a devDependency and commit the ${PACKAGE_MANAGER} lockfile"
	fi

	# Install browser binaries
	log_info "Installing Playwright browsers..."
	if [[ "$BROWSER" == "all" ]]; then
		pm_exec playwright install --with-deps
	else
		pm_exec playwright install --with-deps "$BROWSER"
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

	pm_require >/dev/null || exit $?

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

	# Add reporter. *_OUTPUT_FILE outranks *_OUTPUT_NAME in Playwright, so an
	# inherited value would silently redirect the sidecar the parse step reads.
	unset PLAYWRIGHT_JSON_OUTPUT_FILE PLAYWRIGHT_JUNIT_OUTPUT_FILE
	case "$REPORTER" in
	json)
		PLAYWRIGHT_ARGS+=("--reporter=json")
		export PLAYWRIGHT_JSON_OUTPUT_NAME="playwright-results.json"
		;;
	html)
		# HTML reporter with JSON sidecar for machine-readable metrics. One
		# combined flag: Playwright keeps only the last --reporter, so two
		# flags silently dropped the HTML report (#804).
		PLAYWRIGHT_ARGS+=("--reporter=html,json")
		export PLAYWRIGHT_JSON_OUTPUT_NAME="playwright-results.json"
		export PLAYWRIGHT_HTML_OUTPUT_DIR="playwright-report"
		# Legacy name of the same setting (Playwright < 1.45 reads only this one).
		export PLAYWRIGHT_HTML_REPORT="playwright-report"
		export PLAYWRIGHT_HTML_OPEN="never"
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
		if [[ "$EXTRA_ARGS" == *--reporter* ]]; then
			# Playwright keeps only the last --reporter flag, so this replaces
			# the reporter input's set (and its report/sidecar outputs).
			echo "::warning title=reporter::extra-args passes --reporter; it overrides reporter=${REPORTER} and may drop the ${REPORTER} output" >&2
		fi
		read -ra EXTRA_ARRAY <<<"$EXTRA_ARGS"
		PLAYWRIGHT_ARGS+=("${EXTRA_ARRAY[@]}")
	fi

	log_info "Running Playwright with args: ${PLAYWRIGHT_ARGS[*]}"

	exit_code=0
	pm_exec playwright "${PLAYWRIGHT_ARGS[@]}" || exit_code=$?

	case "$REPORTER" in
	json)
		if [[ -f "playwright-results.json" ]]; then
			set_github_output "report-path" "playwright-results.json"
		fi
		;;
	html)
		# The HTML report is what reporter=html promises (the action uploads
		# it): its absence fails the run even when every test passed (#804).
		if [[ -d "playwright-report" ]]; then
			set_github_output "report-path" "playwright-report"
		else
			echo "::error title=Playwright HTML report missing::expected playwright-report/ after playwright ${PLAYWRIGHT_ARGS[*]} (exit ${exit_code})" >&2
			if [[ "$exit_code" -eq 0 ]]; then
				exit_code=1
			fi
		fi
		# Also output JSON sidecar path for parsing
		if [[ -f "playwright-results.json" ]]; then
			set_github_output "json-report-path" "playwright-results.json"
		fi
		;;
	junit)
		if [[ -f "playwright-results.xml" ]]; then
			set_github_output "report-path" "playwright-results.xml"
		fi
		;;
	esac

	# Set outputs (after the report checks, which may raise the code)
	set_github_output "exit-code" "$exit_code"

	exit "$exit_code"
	;;

parse)
	: "${REPORT_PATH:=playwright-results.json}"
	: "${REPORTER:=json}"

	# Parse test results based on reporter type
	case "$REPORTER" in
	json | html)
		# For HTML reporter, use the JSON sidecar for metrics
		# Honor REPORT_PATH if it exists, otherwise fallback to default
		json_file="$REPORT_PATH"
		if [[ "$REPORTER" == "html" ]] && [[ ! -f "$json_file" ]]; then
			json_file="playwright-results.json"
		fi

		if [[ -f "$json_file" ]]; then
			if parse_playwright_json "$json_file"; then
				log_info "Test results: $(format_test_summary)"
			else
				log_warn "Results file is not valid JSON; reporting zero tests: $json_file"
			fi

			set_github_output "tests-passed" "$TESTS_PASSED"
			set_github_output "tests-failed" "$TESTS_FAILED"
			set_github_output "tests-skipped" "$TESTS_SKIPPED"
			set_github_output "tests-total" "$TESTS_TOTAL"
		else
			log_warn "Results file not found: $json_file"
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
			set_github_output "tests-passed" "0"
			set_github_output "tests-failed" "0"
			set_github_output "tests-skipped" "0"
			set_github_output "tests-total" "0"
		fi
		;;
	*)
		log_warn "Cannot parse results for reporter: $REPORTER"
		set_github_output "tests-passed" "0"
		set_github_output "tests-failed" "0"
		set_github_output "tests-skipped" "0"
		set_github_output "tests-total" "0"
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
