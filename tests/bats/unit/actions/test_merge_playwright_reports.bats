#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Tests for scripts/ci/actions/merge-playwright-reports.sh (#804):
#          the stats-only JSON fallback tolerates malformed shard reports.

load "../../../helpers/common"

SCRIPT="${PROJECT_ROOT}/scripts/ci/actions/merge-playwright-reports.sh"

setup() {
	setup_temp_dir
	export INPUT_DIR="${BATS_TEST_TMPDIR}/reports"
	export OUTPUT_DIR="${BATS_TEST_TMPDIR}/merged"
	mkdir -p "$INPUT_DIR"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	teardown_temp_dir
}

_github_output_value() {
	grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-
}

@test "merge-playwright-reports merge: sums per-shard JSON stats" {
	install_fixture "playwright/reports/json-shard-1of2.json" "${INPUT_DIR}/a/playwright-results.json"
	install_fixture "playwright/reports/json-shard-2of2.json" "${INPUT_DIR}/b/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=json bash "$SCRIPT"
	assert_success
	assert_equal "${OUTPUT_DIR}/merged-results.json" "$(_github_output_value merged-path)"
	run jq -c '[.stats.expected, .stats.unexpected, .stats.skipped, .stats.duration]' "${OUTPUT_DIR}/merged-results.json"
	# failed = unexpected + flaky across both shards; duration is the integer-ms
	# sum (2373 + 567), not whole seconds times 1000
	assert_output "[1,2,1,2940]"
	assert_equal "0" "$(_github_output_value unparseable-count)"
}

@test "merge-playwright-reports merge: a malformed shard is skipped, never used as base" {
	# Sorted first so it would have been the base before #804.
	install_fixture "playwright/reports/json-malformed.json" "${INPUT_DIR}/0-broken/playwright-results.json"
	install_fixture "playwright/reports/json-shard-2of2.json" "${INPUT_DIR}/1-ok/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=json bash "$SCRIPT"
	assert_success
	assert_output --partial "Unparseable Playwright report skipped"
	assert_output --partial "::warning title=Playwright merge::1 shard report(s) were not valid JSON"
	assert_equal "1" "$(_github_output_value unparseable-count)"
	run jq -c '[.stats.expected, .stats.unexpected, .stats.skipped]' "${OUTPUT_DIR}/merged-results.json"
	assert_output "[1,0,1]"
}

@test "merge-playwright-reports summary: shows skipped invalid reports" {
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
	: >"$GITHUB_STEP_SUMMARY"

	run env STEP=summary TOTAL_PASSED=1 TOTAL_FAILED=0 TOTAL_SKIPPED=1 REPORT_COUNT=2 UNPARSEABLE_COUNT=1 bash "$SCRIPT"
	assert_success
	run cat "$GITHUB_STEP_SUMMARY"
	assert_output --partial "| Reports skipped (invalid JSON) | :warning: 1 |"
}

@test "merge-playwright-reports merge: only malformed reports yields no merged path" {
	install_fixture "playwright/reports/json-malformed.json" "${INPUT_DIR}/a/playwright-results.json"

	run env STEP=merge REPORT_FORMAT=json bash "$SCRIPT"
	assert_success
	assert_output --partial "No valid JSON reports found to merge"
	assert_equal "" "$(_github_output_value merged-path)"
	assert_file_not_exists "${OUTPUT_DIR}/merged-results.json"
}

@test "merge-playwright-reports parse-merged: malformed merged file reports zero tests" {
	install_fixture "playwright/reports/json-malformed.json" "${BATS_TEST_TMPDIR}/merged-results.json"

	run env STEP=parse-merged MERGED_PATH="${BATS_TEST_TMPDIR}/merged-results.json" bash "$SCRIPT"
	assert_success
	assert_output --partial "not valid JSON"
	assert_equal "0" "$(_github_output_value total-passed)"
}

@test "merge-playwright-reports parse-merged: reads a merge-reports JSON" {
	install_fixture "playwright/reports/json-merged.json" "${BATS_TEST_TMPDIR}/merged-results.json"

	run env STEP=parse-merged MERGED_PATH="${BATS_TEST_TMPDIR}/merged-results.json" bash "$SCRIPT"
	assert_success
	assert_equal "1" "$(_github_output_value total-passed)"
	assert_equal "2" "$(_github_output_value total-failed)"
	assert_equal "1" "$(_github_output_value total-skipped)"
}
