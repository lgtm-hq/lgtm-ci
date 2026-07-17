#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Playwright E2E helpers for reusable-test-e2e-playwright.yml
#
# Required environment variables:
#   STEP - cache-key | assemble-args | install-browsers | run | parse | summary | upload-gate
#
# STEP=assemble-args is a unit-test / direct-invocation helper that writes
# filter-args to GITHUB_OUTPUT. The workflow uses STEP=run, which calls
# assemble_playwright_filter_args() internally.
#
# Optional environment variables (by step):
#   WORKING_DIRECTORY - Project directory (default: .)
#   BROWSERS - Browser list for install/cache (default: chromium); "all" installs all
#   TEST_COMMAND - Base CLI command (default: npx playwright test)
#   PROJECT - Playwright --project filter
#   GREP - Playwright --grep filter
#   BASE_URL - Exported as BASE_URL / PLAYWRIGHT_BASE_URL for config passthrough
#   WEB_SERVER - Exported as PLAYWRIGHT_WEB_SERVER for config passthrough
#   UPLOAD_REPORT - true/false; with EXIT_CODE gates artifact upload
#   EXIT_CODE - Playwright process exit code for upload-gate / summary
#   TESTS_PASSED / TESTS_FAILED / TESTS_SKIPPED / TESTS_TOTAL - summary inputs
#   REPORT_PATH - JSON results path for parse (default: playwright-results.json)

set -euo pipefail

: "${STEP:?STEP is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing.sh
source "$SCRIPT_DIR/../lib/testing.sh"

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

# Resolve @playwright/test version from package.json / lockfiles for cache keys.
resolve_playwright_version() {
	local working_directory="$1"
	local version=""

	if [[ -f "${working_directory}/package.json" ]]; then
		version="$(
			node -e '
				const fs = require("fs");
				const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
				const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
				const raw = deps["@playwright/test"] || deps.playwright || "";
				process.stdout.write(String(raw).replace(/^[\^~>=<\s]+/, ""));
			' "${working_directory}/package.json" 2>/dev/null || true
		)"
	fi

	if [[ -z "$version" ]] && command -v npx >/dev/null 2>&1; then
		version="$(
			cd "$working_directory" &&
				npx --no-install playwright --version 2>/dev/null |
				awk '{print $NF; exit}' || true
		)"
	fi

	if [[ -z "$version" ]]; then
		version="unknown"
	fi

	printf '%s' "$version"
}

# Build Playwright CLI filter args from PROJECT / GREP (space-separated tokens).
assemble_playwright_filter_args() {
	local project grep_pattern
	project="$(trim "${PROJECT:-}")"
	grep_pattern="$(trim "${GREP:-}")"

	local -a args=()
	if [[ -n "$project" ]]; then
		args+=("--project=${project}")
	fi
	if [[ -n "$grep_pattern" ]]; then
		args+=("--grep=${grep_pattern}")
	fi

	if [[ ${#args[@]} -eq 0 ]]; then
		printf ''
		return 0
	fi
	printf '%s' "${args[*]}"
}

case "$STEP" in
cache-key)
	: "${WORKING_DIRECTORY:=.}"
	: "${BROWSERS:=chromium}"

	working_directory="$(trim "$WORKING_DIRECTORY")"
	browsers="$(trim "$BROWSERS")"
	if [[ -z "$working_directory" ]]; then
		working_directory="."
	fi
	if [[ -z "$browsers" ]]; then
		browsers="chromium"
	fi

	version="$(resolve_playwright_version "$working_directory")"
	# Stable key fragment: version + browsers (workflow prefixes OS).
	cache_key="playwright-${version}-${browsers}"
	cache_key="${cache_key// /-}"

	set_github_output "playwright-version" "$version"
	set_github_output "cache-key" "$cache_key"
	log_info "Playwright cache key: ${cache_key} (version=${version})"
	;;

assemble-args)
	filter_args="$(assemble_playwright_filter_args)"
	set_github_output "filter-args" "$filter_args"
	if [[ -n "$filter_args" ]]; then
		log_info "Playwright filter args: ${filter_args}"
	else
		log_info "No Playwright project/grep filters"
	fi
	;;

install-browsers)
	: "${WORKING_DIRECTORY:=.}"
	: "${BROWSERS:=chromium}"

	working_directory="$(trim "$WORKING_DIRECTORY")"
	browsers="$(trim "$BROWSERS")"
	if [[ -z "$working_directory" ]]; then
		working_directory="."
	fi
	if [[ -z "$browsers" ]]; then
		browsers="chromium"
	fi

	cd "$working_directory"
	log_info "Installing Playwright browsers (${browsers})..."

	if [[ "$browsers" == "all" ]]; then
		npx playwright install --with-deps
	else
		# shellcheck disable=SC2086 # intentional word-split of browser list
		npx playwright install --with-deps ${browsers}
	fi

	log_success "Playwright browser install complete"
	;;

run)
	: "${WORKING_DIRECTORY:=.}"
	: "${TEST_COMMAND:=npx playwright test}"
	: "${PROJECT:=}"
	: "${GREP:=}"
	: "${BASE_URL:=}"
	: "${WEB_SERVER:=}"

	working_directory="$(trim "$WORKING_DIRECTORY")"
	test_command="$(trim "$TEST_COMMAND")"
	base_url="$(trim "$BASE_URL")"
	web_server="$(trim "$WEB_SERVER")"

	if [[ -z "$working_directory" ]]; then
		working_directory="."
	fi
	if [[ -z "$test_command" ]]; then
		echo "::error::TEST_COMMAND must not be empty" >&2
		exit 1
	fi
	if [[ ! -d "$working_directory" ]]; then
		echo "::error::Working directory does not exist: ${working_directory}" >&2
		exit 1
	fi

	cd "$working_directory"

	if [[ -n "$base_url" ]]; then
		export BASE_URL="$base_url"
		export PLAYWRIGHT_BASE_URL="$base_url"
		log_info "BASE_URL / PLAYWRIGHT_BASE_URL=${base_url}"
	fi
	if [[ -n "$web_server" ]]; then
		export PLAYWRIGHT_WEB_SERVER="$web_server"
		log_info "PLAYWRIGHT_WEB_SERVER=${web_server}"
	fi

	filter_args="$(assemble_playwright_filter_args)"
	# JSON sidecar for metrics + HTML report for failure artifacts.
	export PLAYWRIGHT_JSON_OUTPUT_NAME="${PLAYWRIGHT_JSON_OUTPUT_NAME:-playwright-results.json}"

	full_command="${test_command}"
	if [[ -n "$filter_args" ]]; then
		full_command="${full_command} ${filter_args}"
	fi
	# Ensure machine-readable + HTML reporters for parse/upload (additive).
	full_command="${full_command} --reporter=html --reporter=json"

	log_info "Running Playwright: ${full_command}"

	exit_code=0
	bash -euo pipefail -c "$full_command" || exit_code=$?

	set_github_output "exit-code" "$exit_code"
	if [[ -f "playwright-results.json" ]]; then
		set_github_output "report-path" "playwright-results.json"
		set_github_output "json-report-path" "playwright-results.json"
	fi
	if [[ -d "playwright-report" ]]; then
		set_github_output "html-report-path" "playwright-report"
	fi

	exit "$exit_code"
	;;

parse)
	: "${REPORT_PATH:=playwright-results.json}"
	: "${WORKING_DIRECTORY:=.}"

	working_directory="$(trim "$WORKING_DIRECTORY")"
	if [[ -z "$working_directory" ]]; then
		working_directory="."
	fi

	json_file="$REPORT_PATH"
	if [[ "$json_file" != /* && ! -f "$json_file" && -f "${working_directory}/${json_file}" ]]; then
		json_file="${working_directory}/${json_file}"
	fi

	if [[ -f "$json_file" ]]; then
		parse_playwright_json "$json_file"
		set_github_output "tests-passed" "$TESTS_PASSED"
		set_github_output "tests-failed" "$TESTS_FAILED"
		set_github_output "tests-skipped" "$TESTS_SKIPPED"
		set_github_output "tests-total" "$TESTS_TOTAL"
		log_info "Test results: $(format_test_summary)"
	else
		log_warn "Results file not found: $json_file"
		set_github_output "tests-passed" "0"
		set_github_output "tests-failed" "0"
		set_github_output "tests-skipped" "0"
		set_github_output "tests-total" "0"
	fi
	;;

summary)
	: "${TESTS_PASSED:=0}"
	: "${TESTS_FAILED:=0}"
	: "${TESTS_SKIPPED:=0}"
	: "${TESTS_TOTAL:=0}"
	: "${BROWSERS:=chromium}"
	: "${EXIT_CODE:=0}"
	: "${PROJECT:=}"
	: "${GREP:=}"

	add_github_summary "## Playwright E2E Results"
	add_github_summary ""

	if [[ "$EXIT_CODE" -eq 0 ]]; then
		add_github_summary "**Status:** :white_check_mark: Passed"
	else
		add_github_summary "**Status:** :x: Failed"
	fi
	add_github_summary ""

	if [[ "$TESTS_TOTAL" -gt 0 ]]; then
		add_github_summary "| Metric | Value |"
		add_github_summary "|--------|-------|"
		add_github_summary "| Browsers | $BROWSERS |"
		if [[ -n "$(trim "${PROJECT:-}")" ]]; then
			add_github_summary "| Project | $PROJECT |"
		fi
		if [[ -n "$(trim "${GREP:-}")" ]]; then
			add_github_summary "| Grep | $GREP |"
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

upload-gate)
	: "${UPLOAD_REPORT:=false}"
	: "${EXIT_CODE:=0}"

	upload_report="$(trim "$UPLOAD_REPORT")"
	exit_code="$(trim "$EXIT_CODE")"
	: "${exit_code:=0}"

	should_upload="false"
	if [[ "$upload_report" == "true" && "$exit_code" != "0" ]]; then
		should_upload="true"
	fi

	set_github_output "should-upload" "$should_upload"
	log_info "Report upload gate: should-upload=${should_upload} (upload-report=${upload_report}, exit-code=${exit_code})"
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
