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
#   REPORTERS - Comma-separated reporter set passed as ONE --reporter flag
#               (default: list,json,junit,html). Must contain json (parse
#               reads the sidecar) and html (asserted after the run, #804).
#   BASE_URL - Exported as BASE_URL / PLAYWRIGHT_BASE_URL for config passthrough
#   WEB_SERVER - Exported as PLAYWRIGHT_WEB_SERVER for config passthrough
#   UPLOAD_REPORT - true/false; with EXIT_CODE gates artifact upload
#   UPLOAD_REPORT_WHEN - failure (default) or always; narrows UPLOAD_REPORT
#   EXIT_CODE - Playwright process exit code for upload-gate / summary
#   TESTS_PASSED / TESTS_FAILED / TESTS_SKIPPED / TESTS_TOTAL - summary inputs
#   REPORT_PATH - JSON results path for parse (default: playwright-results.json)
#   MATRIX_KEY / MATRIX_VALUE - matrix coordinate recorded in results.v1
#   RESULTS_OUTPUT - results.v1 path (default results/playwright/<matrix-value|default>/results.json)
#   RESULTS_FILE - summary step: results.v1 document to render

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

	# Prefer the installed binary: it reflects the lockfile-resolved version,
	# so lockfile-only upgrades rotate the cache key.
	if command -v npx >/dev/null 2>&1; then
		version="$(
			cd "$working_directory" &&
				npx --no-install playwright --version 2>/dev/null |
				awk '{print $NF; exit}' || true
		)"
	fi

	if [[ -z "$version" && -f "${working_directory}/package.json" ]]; then
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

	# Shell-quote each filter: the run step re-parses the assembled command
	# through `bash -c`, so raw spaces/metacharacters would split or expand.
	local -a args=()
	if [[ -n "$project" ]]; then
		args+=("$(printf '%q' "--project=${project}")")
	fi
	if [[ -n "$grep_pattern" ]]; then
		args+=("$(printf '%q' "--grep=${grep_pattern}")")
	fi

	if [[ ${#args[@]} -eq 0 ]]; then
		printf ''
		return 0
	fi
	printf '%s' "${args[*]}"
}

# Normalize REPORTERS into the comma-separated value of one --reporter flag.
# Playwright keeps only the last --reporter flag on the CLI, so emitting
# `--reporter=html --reporter=json` silently dropped the HTML report (#804).
# Prints the normalized list; fails when json or html is absent.
normalize_playwright_reporters() {
	local raw="${1:-}"
	local -a parts=() kept=()
	local part has_json=0 has_html=0

	IFS=',' read -ra parts <<<"$raw"
	for part in "${parts[@]}"; do
		part="$(trim "$part")"
		[[ -z "$part" ]] && continue
		# Entries are built-in names (`html`) or paths to custom reporters;
		# only the bare names take part in the json/html check.
		case "$part" in
		json) has_json=1 ;;
		html) has_html=1 ;;
		esac
		kept+=("$part")
	done

	if [[ ${#kept[@]} -eq 0 ]]; then
		echo "::error title=reporters::reporters must not be empty (default: list,json,junit,html)" >&2
		return 1
	fi
	if [[ "$has_json" -ne 1 || "$has_html" -ne 1 ]]; then
		echo "::error title=reporters::reporters must include json (metrics sidecar) and html (uploaded report); got '${raw}'" >&2
		return 1
	fi

	local IFS=','
	printf '%s' "${kept[*]}"
}

# True when the comma-separated reporter list contains the bare name.
reporters_include() {
	local list="$1" wanted="$2" part
	local -a parts=()
	IFS=',' read -ra parts <<<"$list"
	for part in "${parts[@]}"; do
		[[ "$part" == "$wanted" ]] && return 0
	done
	return 1
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
	: "${REPORTERS:=list,json,junit,html}"
	: "${BASE_URL:=}"
	: "${WEB_SERVER:=}"

	working_directory="$(trim "$WORKING_DIRECTORY")"
	test_command="$(trim "$TEST_COMMAND")"
	base_url="$(trim "$BASE_URL")"
	web_server="$(trim "$WEB_SERVER")"

	if [[ -z "$working_directory" ]]; then
		working_directory="."
	fi
	# Pre-run validation failures still publish exit-code=1: the workflow's
	# run step is continue-on-error and the final verdict step re-raises only
	# a non-empty, non-zero exit-code, so exiting without it left the job green.
	if [[ -z "$test_command" ]]; then
		echo "::error::TEST_COMMAND must not be empty" >&2
		set_github_output "exit-code" "1"
		exit 1
	fi
	if [[ ! -d "$working_directory" ]]; then
		echo "::error::Working directory does not exist: ${working_directory}" >&2
		set_github_output "exit-code" "1"
		exit 1
	fi
	if ! reporters="$(normalize_playwright_reporters "$REPORTERS")"; then
		set_github_output "exit-code" "1"
		exit 1
	fi
	if [[ "$test_command" == *--reporter* ]]; then
		echo "::warning title=reporters::test-command already passes --reporter; Playwright keeps only the last flag, so the reporters input (${reporters}) wins" >&2
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
	# Fixed output locations, assigned unconditionally: parse reads the JSON
	# sidecar and the workflow's upload step globs these exact paths, so an
	# inherited override would pass the HTML check while the artifact and
	# metrics came up empty. Env wins over any outputFile the consumer config
	# sets, because the CLI --reporter below replaces the config reporters.
	export PLAYWRIGHT_JSON_OUTPUT_NAME="playwright-results.json"
	export PLAYWRIGHT_JUNIT_OUTPUT_NAME="playwright-results.xml"
	export PLAYWRIGHT_HTML_OUTPUT_DIR="playwright-report"
	# Legacy name of the same setting (Playwright < 1.45 reads only this one).
	export PLAYWRIGHT_HTML_REPORT="playwright-report"
	# *_OUTPUT_FILE outranks *_OUTPUT_NAME in Playwright; drop any inherited
	# value so nothing redirects the sidecars.
	unset PLAYWRIGHT_JSON_OUTPUT_FILE PLAYWRIGHT_JUNIT_OUTPUT_FILE
	# Never try to open the HTML report in a browser (the html reporter's
	# default is on-failure outside CI).
	export PLAYWRIGHT_HTML_OPEN="never"

	full_command="${test_command}"
	if [[ -n "$filter_args" ]]; then
		full_command="${full_command} ${filter_args}"
	fi
	# Exactly one --reporter flag: Playwright keeps only the last one, so two
	# flags dropped the HTML report while the run stayed green (#804).
	# Shell-quoted like the filter args: the command is re-parsed by bash -c,
	# and a custom reporter path may contain spaces or metacharacters.
	full_command="${full_command} $(printf '%q' "--reporter=${reporters}")"

	log_info "Running Playwright: ${full_command}"

	exit_code=0
	# env -u BASH_ENV: kcov instruments nested bash via BASH_ENV; its injected
	# script trips `set -u` inside user commands, which are not coverage targets.
	env -u BASH_ENV bash -euo pipefail -c "$full_command" || exit_code=$?

	if [[ -f "playwright-results.json" ]]; then
		set_github_output "report-path" "playwright-results.json"
		set_github_output "json-report-path" "playwright-results.json"
	fi
	if reporters_include "$reporters" junit && [[ -f "playwright-results.xml" ]]; then
		set_github_output "junit-report-path" "playwright-results.xml"
	fi

	# The HTML report is the artifact this workflow promises: its absence is a
	# failure of the run, not a warning, even when every test passed (#804).
	if [[ -d "$PLAYWRIGHT_HTML_OUTPUT_DIR" ]]; then
		set_github_output "html-report-path" "$PLAYWRIGHT_HTML_OUTPUT_DIR"
	else
		echo "::error title=Playwright HTML report missing::expected ${PLAYWRIGHT_HTML_OUTPUT_DIR}/ after '${full_command}' (exit ${exit_code}); the html reporter did not run or wrote elsewhere" >&2
		if [[ "$exit_code" -eq 0 ]]; then
			exit_code=1
		fi
	fi

	set_github_output "exit-code" "$exit_code"
	exit "$exit_code"
	;;

parse)
	: "${REPORT_PATH:=playwright-results.json}"
	: "${WORKING_DIRECTORY:=.}"
	: "${EXIT_CODE:=}"
	: "${MATRIX_KEY:=}"
	: "${MATRIX_VALUE:=}"
	: "${RESULTS_OUTPUT:=$(results_v1_path playwright "${MATRIX_VALUE:-default}")}"

	working_directory="$(trim "$WORKING_DIRECTORY")"
	if [[ -z "$working_directory" ]]; then
		working_directory="."
	fi

	json_file="$REPORT_PATH"
	if [[ "$json_file" != /* && ! -f "$json_file" && -f "${working_directory}/${json_file}" ]]; then
		json_file="${working_directory}/${json_file}"
	fi

	# Native JSON reporter -> results.v1 (#1080). Every public output below
	# is read back from that document, never from parser state.
	artifacts=""
	if [[ -f "$json_file" ]]; then
		artifacts+="report=${json_file}"$'\n'
	else
		log_warn "Results file not found: $json_file"
	fi
	report_dir="$(dirname "$json_file")"
	if [[ -f "${report_dir}/playwright-results.xml" ]]; then
		artifacts+="junit=${report_dir}/playwright-results.xml"$'\n'
	fi
	if [[ -d "${report_dir}/playwright-report" ]]; then
		artifacts+="html-report=${report_dir}/playwright-report"$'\n'
	fi

	mkdir -p "$(dirname "$RESULTS_OUTPUT")"
	RESULTS_ARTIFACTS="$artifacts" playwright_results_v1 "$json_file" >"$RESULTS_OUTPUT"
	results_v1_validate "$RESULTS_OUTPUT"
	results_v1_github_outputs "$RESULTS_OUTPUT"
	set_github_output "results-json" "$RESULTS_OUTPUT"

	if [[ "$(jq -r .status "$RESULTS_OUTPUT")" == "error" && -f "$json_file" ]]; then
		log_warn "Results file is not valid JSON; reporting zero tests: $json_file"
	else
		log_info "Test results: $(format_test_summary)"
	fi
	log_info "results.v1 written: ${RESULTS_OUTPUT}"
	;;

summary)
	: "${BROWSERS:=chromium}"
	: "${PROJECT:=}"
	: "${GREP:=}"
	# Pure renderer over the contract document. The legacy TESTS_* /
	# EXIT_CODE inputs are still accepted: without RESULTS_FILE they are
	# folded into a temporary document first.
	: "${RESULTS_FILE:=}"
	if [[ -z "$RESULTS_FILE" || ! -f "$RESULTS_FILE" ]]; then
		RESULTS_FILE="$(mktemp)"
		RESULTS_TOOL=playwright RESULTS_RUNNER=run-playwright-tests \
			EXIT_CODE="${EXIT_CODE:-0}" results_v1_build >"$RESULTS_FILE"
	fi
	extra_rows="Browsers|${BROWSERS}"
	if [[ -n "$(trim "${PROJECT:-}")" ]]; then
		extra_rows+=$'\n'"Project|${PROJECT}"
	fi
	if [[ -n "$(trim "${GREP:-}")" ]]; then
		extra_rows+=$'\n'"Grep|${GREP}"
	fi
	TITLE="Playwright E2E Results" RESULTS_FILE="$RESULTS_FILE" EXTRA_ROWS="$extra_rows" \
		bash "$SCRIPT_DIR/render-step-summary.sh"
	;;

upload-gate)
	: "${UPLOAD_REPORT:=false}"
	: "${UPLOAD_REPORT_WHEN:=failure}"
	: "${EXIT_CODE:=0}"

	upload_report="$(trim "$UPLOAD_REPORT")"
	upload_when="$(trim "$UPLOAD_REPORT_WHEN")"
	exit_code="$(trim "$EXIT_CODE")"
	: "${exit_code:=0}"
	: "${upload_when:=failure}"

	case "$upload_when" in
	failure | always) ;;
	*)
		echo "::error title=upload-report-when::expected failure or always, got '${upload_when}'" >&2
		exit 1
		;;
	esac

	should_upload="false"
	if [[ "$upload_report" == "true" ]]; then
		if [[ "$upload_when" == "always" || "$exit_code" != "0" ]]; then
			should_upload="true"
		fi
	fi

	set_github_output "should-upload" "$should_upload"
	log_info "Report upload gate: should-upload=${should_upload} (upload-report=${upload_report}, upload-report-when=${upload_when}, exit-code=${exit_code})"
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
