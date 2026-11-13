#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Merge multiple Playwright JSON/HTML reports from shards or matrix jobs
#
# Required environment variables:
#   STEP - Which step to run: collect, merge, parse-merged, summary
#
# Optional environment variables:
#   INPUT_DIR - Directory containing report artifacts (default: playwright-reports).
#               Expect one subdirectory per shard artifact (download-artifact
#               with merge-multiple: false): every shard writes the same
#               playwright-results.json, so a flattened download keeps only
#               the last shard's report (#1474).
#   OUTPUT_DIR - Directory for merged report (default: merged-report)
#   REPORT_FORMAT - Format: json, html (default: html)
#   EXPECTED_MATRIX - merge step: the e2e matrix JSON ({suite, browser, shard}
#                     arrays) the shards ran. When set, the JSON merge fails
#                     unless every shard directory
#                     <ARTIFACT_PREFIX>-<suite>-<browser>-<shard> holds exactly
#                     one results file. Unset skips the check with a warning.
#   ARTIFACT_PREFIX - merge step: shard artifact name prefix (default: playwright)
#   TEST_RESULT - merge step: result of the job that ran the shards (default:
#                 success). When it is not success, missing or invalid shard
#                 reports are expected fallout of that failure: they are
#                 printed as warnings and the merge exits 1 without an
#                 ::error:: annotation of its own.
#   UNPARSEABLE_COUNT - summary step: shard reports skipped as invalid JSON
#                       (merge step output unparseable-count)

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"
# shellcheck source=../lib/testing.sh
source "$SCRIPT_DIR/../lib/testing.sh"

# Shard JSON reports under $1, one path per line in a stable order. Two kinds
# of JSON are not shard results: a previous merge's output (merged-results.json,
# e.g. from an earlier run attempt's merged artifact matching the same download
# pattern) and anything inside an HTML report directory (playwright-report/,
# including the HTML-only playwright-report artifact), whose data/ holds
# attachments.
_shard_json_reports() {
	find "$1" -mindepth 1 \( -type d -name "playwright-report" -prune \) -o \
		\( -type f -name "*.json" -not -name "merged-results.json" -print \) 2>/dev/null |
		LC_ALL=C sort || true
}

# Blob report directories under $1 that hold at least one .zip, one per line.
_blob_report_dirs() {
	local dir
	find "$1" -maxdepth 2 -type d \( -name "blob-report" -o -name "blob-report-*" \) 2>/dev/null |
		LC_ALL=C sort |
		while IFS= read -r dir; do
			if compgen -G "$dir/*.zip" >/dev/null; then
				printf '%s\n' "$dir"
			fi
		done || true
}

# A Playwright JSON report: a suites array and Playwright's four per-test
# outcome counters, each a non-negative integer.
_PLAYWRIGHT_REPORT_SHAPE='
	(.suites | type == "array")
	and (.stats | type == "object")
	and ([.stats.expected, .stats.unexpected, .stats.skipped, .stats.flaky]
		| all(type == "number" and . >= 0 and . == floor))'

# "<passed>/<failed>/<skipped> in suites <same from the stats counters>",
# per category, the way parse_playwright_json maps them (flaky counts as
# failed). Tests are counted by PLAYWRIGHT_JQ_DEFS (lib/testing/parse/
# playwright.sh), the definition parse_playwright_json counts with, so the
# check and the totals agree.
_PLAYWRIGHT_REPORT_COUNTS="${PLAYWRIGHT_JQ_DEFS}"'
	"\(pw_count(pw_passed_status))/\(pw_count(pw_failed_status))/\(pw_count(pw_skipped_status)) \(.stats.expected)/\(.stats.unexpected + .stats.flaky)/\(.stats.skipped)"'

# Checks the shard directories against the expected matrix: each expected
# <prefix>-<suite>-<browser>-<shard> directory must hold exactly one results
# file; that file must be a Playwright JSON report (_PLAYWRIGHT_REPORT_SHAPE)
# whose suites hold as many tests as its stats count; and no results file may
# sit outside them. A shard that never uploaded, or uploaded an empty,
# truncated or inconsistent file, must fail the merge, not shrink the totals
# (#1474). A complete, consistent report of zero tests passes: it is a true
# count, and "each leg ran a test" is the caller's assertion on shard-counts.
# A missing report (no results file at all) is annotated at level $4
# (error or warning); every other problem is always an error, so a
# malformed or inconsistent report from a leg that ran is never excused
# as fallout of another leg's failure.
_check_expected_shards() {
	local input_dir="$1" prefix="$2" matrix="$3" missing_level="$4" level=error
	local names name count found file counts problems=0
	if ! names=$(jq -r --arg prefix "$prefix" \
		'.suite[] as $s | .browser[] as $b | .shard[] as $n | "\($prefix)-\($s)-\($b)-\($n)"' \
		<<<"$matrix" 2>/dev/null) || [[ -z "$names" ]]; then
		echo "::error title=Playwright merge::EXPECTED_MATRIX is not a {suite, browser, shard} matrix: ${matrix}" >&2
		return 1
	fi

	while IFS= read -r name; do
		count=0
		if [[ -d "$input_dir/$name" ]]; then
			count=$(_shard_json_reports "$input_dir/$name" | wc -l | tr -d ' ')
		fi
		if [[ "$count" -eq 0 ]]; then
			echo "::${missing_level} title=Playwright merge::shard ${name}: expected 1 results file, found 0" >&2
			problems=$((problems + 1))
			continue
		fi
		if [[ "$count" -ne 1 ]]; then
			echo "::${level} title=Playwright merge::shard ${name}: expected 1 results file, found ${count}" >&2
			problems=$((problems + 1))
			continue
		fi
		file=$(_shard_json_reports "$input_dir/$name")
		if ! jq -e "$_PLAYWRIGHT_REPORT_SHAPE" "$file" >/dev/null 2>&1; then
			echo "::${level} title=Playwright merge::shard ${name}: ${file#"$input_dir"/} is not a Playwright JSON report (needs a suites array and stats.expected, unexpected, skipped and flaky as non-negative integers)" >&2
			problems=$((problems + 1))
			continue
		fi
		# The merged totals come from the tests in suites (parse_playwright_json
		# counts those first), so stats that claim tests the suites do not hold
		# would publish a count the merge then drops.
		# Fail closed: a jq error (e.g. `tests` not an array) or any output other
		# than two counts must fail the shard, never compare "" with "".
		if ! counts=$(jq -r "$_PLAYWRIGHT_REPORT_COUNTS" "$file" 2>/dev/null) ||
			[[ ! "$counts" =~ ^[0-9]+/[0-9]+/[0-9]+\ [0-9]+/[0-9]+/[0-9]+$ ]]; then
			echo "::${level} title=Playwright merge::shard ${name}: cannot count the tests in ${file#"$input_dir"/} (needs every suites tests value to be an array)" >&2
			problems=$((problems + 1))
			continue
		fi
		if [[ "${counts% *}" != "${counts#* }" ]]; then
			echo "::${level} title=Playwright merge::shard ${name}: ${file#"$input_dir"/} holds ${counts% *} passed/failed/skipped tests in suites but its stats count ${counts#* }" >&2
			problems=$((problems + 1))
		fi
	done <<<"$names"

	# Each expected shard holds one file, so any surplus lies outside them.
	found=$(_shard_json_reports "$input_dir" | wc -l | tr -d ' ')
	count=$(wc -l <<<"$names" | tr -d ' ')
	if [[ "$problems" -eq 0 ]] && [[ "$found" -ne "$count" ]]; then
		echo "::${level} title=Playwright merge::found ${found} results files for ${count} expected shards" >&2
		problems=$((problems + 1))
	fi

	if [[ "$problems" -gt 0 ]]; then
		return 1
	fi
	log_info "All ${count} expected shard reports present"
}

case "$STEP" in
collect)
	: "${INPUT_DIR:=playwright-reports}"
	: "${OUTPUT_DIR:=merged-report}"

	log_info "Collecting Playwright reports from $INPUT_DIR..."

	if [[ ! -d "$INPUT_DIR" ]]; then
		log_warn "Input directory not found: $INPUT_DIR"
		set_github_output "report-count" "0"
		exit 0
	fi

	# Count blob reports (from sharded runs)
	blob_count=$(find "$INPUT_DIR" -name "*.zip" -type f 2>/dev/null | wc -l | tr -d ' ')
	json_count=$(_shard_json_reports "$INPUT_DIR" | wc -l | tr -d ' ')

	log_info "Found $blob_count blob reports and $json_count JSON reports"

	set_github_output "blob-count" "$blob_count"
	set_github_output "json-count" "$json_count"
	set_github_output "report-count" "$((blob_count + json_count))"
	;;

merge)
	: "${INPUT_DIR:=playwright-reports}"
	: "${OUTPUT_DIR:=merged-report}"
	: "${REPORT_FORMAT:=html}"

	mkdir -p "$OUTPUT_DIR"

	# Blob reports: a blob-report/ directory (the reporter's output) or a
	# blob-report-<n> artifact directory (Playwright's documented naming) that
	# holds .zip files. Matching by name alone also caught shard directories of
	# an artifact-prefix starting with "blob" (#1474).
	blob_dirs=$(_blob_report_dirs "$INPUT_DIR")

	# With an expected matrix the shard inventory is checked before any merge
	# path is chosen, and the merge is the JSON merge of exactly the reports
	# checked. The e2e matrix legs only ever write JSON results (run-playwright
	# maps every reporter but junit, blob included, to JSON), so a blob zip in
	# that layout is stale or foreign: it must neither select the blob path
	# past the check nor replace the checked reports (#1474).
	if [[ -n "${EXPECTED_MATRIX:-}" ]]; then
		# A test job that did not succeed (a leg that died before Playwright
		# wrote results) already explains a missing shard report: report only
		# that as a warning and fail without an ::error:: of the merge's own,
		# so the annotations point at the leg that failed. Malformed,
		# inconsistent, duplicate or surplus reports stay errors.
		test_result="${TEST_RESULT:-success}"
		if [[ "$test_result" == "success" ]]; then
			_check_expected_shards "$INPUT_DIR" "${ARTIFACT_PREFIX:-playwright}" "$EXPECTED_MATRIX" error || exit 1
		elif ! _check_expected_shards "$INPUT_DIR" "${ARTIFACT_PREFIX:-playwright}" "$EXPECTED_MATRIX" warning; then
			echo "Playwright merge incomplete: the test job ended ${test_result}, so not every shard report is present" >&2
			exit 1
		fi
		if [[ -n "$blob_dirs" ]]; then
			echo "::warning title=Playwright merge::blob reports ignored with expected-matrix; merging the checked JSON reports: $(tr '\n' ' ' <<<"$blob_dirs")" >&2
			blob_dirs=""
		fi
	else
		echo "::warning title=Playwright merge::expected-matrix not set; a missing shard report is not detected" >&2
	fi

	if [[ -n "$blob_dirs" ]]; then
		log_info "Merging blob reports into $REPORT_FORMAT format..."

		# Verify bunx is available (requires setup-node action)
		if ! command -v bunx &>/dev/null; then
			log_error "bunx not found. Ensure setup-node action runs before this step."
			exit 1
		fi

		# `playwright merge-reports` reads a single directory. With one
		# subdirectory per shard artifact there is one blob-report/ per shard,
		# and their zips can share a name (report-1.zip from every leg with
		# shard index 1), so stage them into one directory under unique names.
		blob_stage="$(mktemp -d)"
		# Removed on any exit, including a failed merge-reports under set -e.
		trap 'rm -rf "$blob_stage"' EXIT
		blob_index=0
		while IFS= read -r blob_dir; do
			if [[ -n "$blob_dir" ]] && [[ -d "$blob_dir" ]]; then
				blob_index=$((blob_index + 1))
				for blob_zip in "$blob_dir"/*.zip; do
					if [[ -f "$blob_zip" ]]; then
						cp "$blob_zip" "$blob_stage/shard${blob_index}-$(basename "$blob_zip")"
					fi
				done
			fi
		done <<<"$blob_dirs"

		bunx playwright merge-reports "--reporter=$REPORT_FORMAT" "$blob_stage"

		# Move output to target directory
		if [[ "$REPORT_FORMAT" == "html" ]] && [[ -d "playwright-report" ]]; then
			mv playwright-report/* "$OUTPUT_DIR/" 2>/dev/null || true
		fi
	else
		# Fallback for JSON reports (no blob reports found): concatenate every
		# parseable shard's suites and errors into the first one, and set the
		# stats to the shard totals. parse-merged counts the tests in the
		# suites before it falls back to the stats, so a merged file holding
		# only the first shard's suites reported that shard alone (#1474).
		log_info "Merging JSON reports (suites and stats)..."

		json_files=$(_shard_json_reports "$INPUT_DIR")

		if [[ -z "$json_files" ]]; then
			log_warn "No reports found to merge"
			set_github_output "merged-path" ""
			exit 0
		fi

		combined_file="$OUTPUT_DIR/merged-results.json"

		total_passed=0
		total_failed=0
		total_skipped=0
		total_duration_ms=0
		unparseable=0
		valid_files=()
		shard_counts='[]'

		while IFS= read -r file; do
			if [[ ! -f "$file" ]]; then
				continue
			fi
			# A malformed shard report (rc 2) contributes nothing and is never
			# the merge base; keep merging the others rather than aborting
			# under set -e, but count it so the summary cannot read as green.
			if ! parse_playwright_json "$file"; then
				log_warn "Unparseable Playwright report skipped: $file"
				unparseable=$((unparseable + 1))
				continue
			fi
			valid_files+=("$file")
			log_info "Shard report ${file#"$INPUT_DIR"/}: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped"
			total_passed=$((total_passed + TESTS_PASSED))
			total_failed=$((total_failed + TESTS_FAILED))
			total_skipped=$((total_skipped + TESTS_SKIPPED))
			total_duration_ms=$((total_duration_ms + TESTS_DURATION_MS))
			shard_counts=$(jq -c \
				--arg report "${file#"$INPUT_DIR"/}" \
				--argjson passed "$TESTS_PASSED" \
				--argjson failed "$TESTS_FAILED" \
				--argjson skipped "$TESTS_SKIPPED" \
				'. + [{report: $report, passed: $passed, failed: $failed, skipped: $skipped}]' \
				<<<"$shard_counts")
		done <<<"$json_files"

		set_github_output "unparseable-count" "$unparseable"

		if [[ ${#valid_files[@]} -eq 0 ]]; then
			# Every report was rejected: still publish the count so the summary
			# shows the skipped reports instead of an all-green zero.
			log_warn "No valid JSON reports found to merge"
			echo "::warning title=Playwright merge::${unparseable} shard report(s) were not valid JSON; nothing merged" >&2
			set_github_output "merged-path" ""
			exit 0
		fi
		if [[ "$unparseable" -gt 0 ]]; then
			echo "::warning title=Playwright merge::${unparseable} shard report(s) were not valid JSON and contributed no counts" >&2
		fi

		# Duration is the integer-ms sum of the shards. Failed already includes
		# flaky (parse_playwright_json folds it in), so flaky is 0: keeping the
		# base shard's flaky would count those tests twice.
		jq -s \
			--argjson passed "$total_passed" \
			--argjson failed "$total_failed" \
			--argjson skipped "$total_skipped" \
			--argjson duration "$total_duration_ms" \
			'def all_of(k): map(if type == "object" then (.[k] // []) else [] end) | add;
			(.[0] | if type == "object" then . else {} end)
			+ {suites: all_of("suites"), errors: all_of("errors")}
			| .stats = ((.stats // {}) + {expected: $passed, unexpected: $failed, skipped: $skipped, flaky: 0, duration: $duration})' \
			"${valid_files[@]}" >"$combined_file"

		# The published totals come from parsing the merged file (parse-merged),
		# shard-counts from parsing each shard. They must agree; they would not
		# if, say, a stats-only shard were merged with shards that hold tests in
		# suites (the merged suites hide its stats). Fail rather than publish a
		# total that drops tests (#1474).
		parse_playwright_json "$combined_file" || true
		if [[ "$TESTS_PASSED $TESTS_FAILED $TESTS_SKIPPED" != "$total_passed $total_failed $total_skipped" ]]; then
			echo "::error title=Playwright merge::merged report counts ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped but the shards sum to ${total_passed} passed, ${total_failed} failed, ${total_skipped} skipped (for example, a report whose tests are only in its stats, merged with reports that hold tests in suites)" >&2
			exit 1
		fi

		set_github_output "shard-counts" "$shard_counts"
	fi

	# Set outputs
	if [[ -f "$OUTPUT_DIR/merged-results.json" ]]; then
		set_github_output "merged-path" "$OUTPUT_DIR/merged-results.json"
	elif [[ -f "$OUTPUT_DIR/index.html" ]]; then
		set_github_output "merged-path" "$OUTPUT_DIR"
	else
		set_github_output "merged-path" "$OUTPUT_DIR"
	fi

	log_success "Reports merged to $OUTPUT_DIR"
	;;

parse-merged)
	# Parse merged results JSON to extract test counts
	: "${MERGED_PATH:=}"

	# Find JSON file in merged output
	json_file=""
	if [[ -f "$MERGED_PATH" ]] && [[ "$MERGED_PATH" == *.json ]]; then
		json_file="$MERGED_PATH"
	elif [[ -d "$MERGED_PATH" ]]; then
		json_file=$(find "$MERGED_PATH" -name "*.json" -type f 2>/dev/null | head -1 || true)
	fi

	if [[ -n "$json_file" ]] && [[ -f "$json_file" ]]; then
		log_info "Parsing merged results from: $json_file"
		parse_playwright_json "$json_file" || log_warn "Merged results are not valid JSON; reporting zero tests: $json_file"
		set_github_output "total-passed" "$TESTS_PASSED"
		set_github_output "total-failed" "$TESTS_FAILED"
		set_github_output "total-skipped" "$TESTS_SKIPPED"
		log_success "Parsed: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped"
	else
		log_warn "No JSON results file found in: $MERGED_PATH"
		set_github_output "total-passed" "0"
		set_github_output "total-failed" "0"
		set_github_output "total-skipped" "0"
	fi
	;;

summary)
	: "${TOTAL_PASSED:=0}"
	: "${TOTAL_FAILED:=0}"
	: "${TOTAL_SKIPPED:=0}"
	: "${REPORT_COUNT:=0}"
	: "${UNPARSEABLE_COUNT:=0}"

	total=$((TOTAL_PASSED + TOTAL_FAILED + TOTAL_SKIPPED))

	add_github_summary "## Playwright Merged Results"
	add_github_summary ""

	if [[ "$TOTAL_FAILED" -eq 0 ]]; then
		add_github_summary "**Status:** :white_check_mark: All tests passed"
	else
		add_github_summary "**Status:** :x: $TOTAL_FAILED tests failed"
	fi
	add_github_summary ""

	add_github_summary "| Metric | Value |"
	add_github_summary "|--------|-------|"
	add_github_summary "| Reports merged | $REPORT_COUNT |"
	if [[ "$UNPARSEABLE_COUNT" -gt 0 ]]; then
		add_github_summary "| Reports skipped (invalid JSON) | :warning: $UNPARSEABLE_COUNT |"
	fi
	add_github_summary "| Passed | $TOTAL_PASSED |"
	add_github_summary "| Failed | $TOTAL_FAILED |"
	add_github_summary "| Skipped | $TOTAL_SKIPPED |"
	add_github_summary "| Total | $total |"
	add_github_summary ""
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
